// The main contract that controls the carbon credits project 

#include "aux/deploy-carbon-fa2.mligo"

(* =============================================================================
 * Storage
 * ============================================================================= *)

type project_owner = address
type project_address = address 
type token = { token_address : address ; token_id : nat ; }

type create = { token_id : nat ; token_metadata : (string, bytes) map ; }
type mint   = { owner : address ; token_id : nat ; qty : nat ; } // = mintburn_data
type bury   = { project_address : address ; token_id : nat ; qty : nat ; }

type create_project = create list
type mint_tokens    = mint list
type bury_carbon    = bury list


// This contract keeps the admin's (the company's) address as well 
//   as a big map of all the projects.
//   This map's key is a project owner, so one address can only 
//   own one project.
type storage = {
    admin : address ;
    projects : (project_owner, project_address) big_map ;
    c4x_address : address ;
}

(* =============================================================================
 * Entrypoint Type Definition
 * ============================================================================= *)

type entrypoint = 
| CreateProject of create_project 
| MintTokens of mint_tokens
| BuryCarbon of bury_carbon 
| UpdateC4XAddress of address

type result = (operation list) * storage

(* =============================================================================
 * Error codes
 * ============================================================================= *)

let error_PROJECT_NOT_FOUND = 0n
let error_PERMISSIONS_DENIED = 1n
let error_COULD_NOT_GET_ENTRYPOINT = 2n
let error_COLLISION = 3n

(* =============================================================================
 * Auxiliary Functions
 * ============================================================================= *)

// an auxiliary function that takes parameters to the BuryCarbon entrypoint 
// and changes them to an operation that pings the FA2 contrac and burns the 
// tokens
let param_to_burn (b : bury) : operation = 
    // ensure only the owner can burn his/her tokens
    let owner = Tezos.source in 
    // get op data
    let txndata_burn : mintburn = 
        [ { owner = owner; token_id = b.token_id; qty = b.qty } ; ] in
    let entrypoint_burn =
        match (Tezos.get_entrypoint_opt "%burn" b.project_address : mintburn contract option) with 
        | None -> (failwith error_COULD_NOT_GET_ENTRYPOINT : mintburn contract)
        | Some c -> c in 
    // create the operation
    Tezos.transaction txndata_burn 0tez entrypoint_burn


(* =============================================================================
 * Entrypoint Functions
 * ============================================================================= *)

// The entrypoint function that creates a project
//   the input type create_project is a list of pairs of (nat * token_metadata)
//   This corresponds to (token_id, token_metadata) of the new FA2 contract. Each 
//   pair will correspond with a project's "zone", which has its unique token id ( : nat )
//   and token metadata. Token metadata has type (string, bytes) map
// type create_project = (nat * token_metadata) list
let create_project (param : create_project) (storage : storage) : result = 
    let owner = Tezos.source in 
    // check the project owner doesn't already have a project 
    if Big_map.mem owner storage.projects then (failwith error_COLLISION : result) else
    // construct the initial storage for your project's FA2 contract
    let ledger    = (Big_map.empty : (fa2_owner * fa2_token_id , fa2_amt) big_map) in 
    let operators = (Big_map.empty : (fa2_owner * fa2_operator * fa2_token_id, unit) big_map) in  
    let metadata = 
        List.fold_left 
        (fun (acc, c : ((fa2_token_id, token_metadata) big_map) * create ) 
            -> Big_map.update c.token_id (Some c.token_metadata : (string, bytes) map option) acc ) // ensures no duplicate token ids 
        (Big_map. empty : (fa2_token_id, token_metadata) big_map)
        param in 
    // initiate an FA2 contract w/permissions given to project contract
    let fa2_init_storage : storage_fa2 = {
        carbon_contract = Tezos.self_address ;
        ledger = ledger ;
        operators = operators ;
        metadata = metadata ; } in 
    let (op_new_fa2,addr_new_fa2) = 
        deploy_carbon_fa2 (None : key_hash option) 0tez fa2_init_storage in
    // update the c4x whitelist
    let txndata_whitelist : (token * (unit option)) list = 
        List.map
        (fun (c : create) -> 
            ({ token_address = addr_new_fa2 ; token_id = c.token_id ; }, (Some ())) )
        param in
    let entrypoint_whitelist : (token * (unit option)) list contract =
        match (Tezos.get_entrypoint_opt "%whitelistTokens" storage.c4x_address : (token * (unit option)) list contract option) with
        | None -> (failwith error_COULD_NOT_GET_ENTRYPOINT : (token * (unit option)) list contract)
        | Some e -> e in 
    let op_whitelist = Tezos.transaction txndata_whitelist 0tez entrypoint_whitelist in
    // update the local storage
    let storage = { storage with 
        projects = Big_map.update owner (Some addr_new_fa2 : project_address option) storage.projects ; } in 
    ([ op_new_fa2 ; op_whitelist ; ], storage)


//  The entrypoint function that a project owner uses to mint new tokens 
//      The input type mint_tokens is a list of triples: (address * nat * nat) list
//      This denotes the to-be owner of the minted tokens, the token id, and the amount, in that order
//      A project owner can submit multiple mints by including them all as a list
let mint_tokens (param : mint_tokens) (storage : storage) : result = 
    let proj_owner = Tezos.sender in 
    // TODO: permissions to regulate minting 
    let addr_proj : address =
        match Big_map.find_opt proj_owner storage.projects with
        | None -> (failwith error_PROJECT_NOT_FOUND : address)
        | Some a -> a in 
    let txndata_mint = param in 
    let entrypoint_mint =
        match (Tezos.get_entrypoint_opt "%mint" addr_proj : mint_tokens contract option) with 
        | None -> (failwith error_COULD_NOT_GET_ENTRYPOINT : mint_tokens contract)
        | Some c -> c in 
    let op_mint = Tezos.transaction txndata_mint 0tez entrypoint_mint in 
    ([ op_mint ;], storage)

// The entrypoint function to "bury" carbon, by burning the carbon tokens 
//      This uses the `param_to_burn` function defined in the aux functions,
//      which takes the input and makes it into a burn operation
// The input type bury_carbon is a list of triples: (address * nat * nat) list
//      This represents the owner of the tokens to be burned, the token id, and the 
//      amt to burn, in that order
// type bury_carbon = (address * nat * nat) list 
let bury_carbon (param : bury_carbon) (storage : storage) : result = 
    let ops_burn = List.map param_to_burn param in 
    (ops_burn, storage)

// This is a function for bootstrapping these contracts onto the chain, since both
// the carbon contract and the c4x contract need to know each other's addresses
let update_c4x_address (c4x_address : address) (storage : storage) : result = 
    let null_address = ("tz1Ke2h7sDdakHJQh8WX4Z372du1KChsksyU" : address) in 
    // check permissions
    if Tezos.sender <> storage.admin then (failwith error_PERMISSIONS_DENIED : result) else
    // this address can only change once
    if storage.c4x_address <> null_address 
    then ([] : operation list), storage
    else ([] : operation list), { storage with c4x_address = c4x_address ; }


(* =============================================================================
 * Main
 * ============================================================================= *)

// One calls an entrypoint by sending a transaction with a parameter which can 
//   be matched to one of these patterns specified below.
// The main function matches the pattern and executes the corresponding 
//   entrypont function.
let main (entrypoint, storage : entrypoint * storage) : result =
    match entrypoint with 
    | CreateProject param ->
        create_project param storage
    | MintTokens param ->
        mint_tokens param storage
    | BuryCarbon param ->
        bury_carbon param storage
    | UpdateC4XAddress param ->
        update_c4x_address param storage
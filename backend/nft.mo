import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Hash "mo:base/Hash";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

persistent actor NftCanister {

  // Types
  public type Account = {
    owner : Principal;
    subaccount : ?Blob;
  };

  // ICRC-7 standard transfer types (one entry per token).
  public type TransferArg = {
    from_subaccount : ?Blob;
    to : Account;
    token_id : Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #NonExistingTokenId;
    #InvalidRecipient;
    #Unauthorized;
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #GenericError : { error_code : Nat; message : Text };
    #GenericBatchError : { error_code : Nat; message : Text };
  };

  public type TransferResult = {
    #Ok : Nat; // transaction index
    #Err : TransferError;
  };

  public type Metadata = [(Text, MetadataValue)];

  public type MetadataValue = {
    #Nat : Nat;
    #Int : Int;
    #Text : Text;
    #Blob : Blob;
    #Map : [(Text, MetadataValue)];
    #Array : [MetadataValue];
  };

  // State
  stable var nextTokenId : Nat = 0;
  stable var tokenOwners : [(Nat, Account)] = [];
  stable var tokenMetadata : [(Nat, Metadata)] = [];
  stable var collectionName : Text = "Infinity Arcade NFTs";
  stable var collectionSymbol : Text = "IANFT";
  stable var collectionDescription : Text = "NFTs for the Infinity Arcade on-chain gaming platform";
  stable var collectionLogo : Text = ""; // URL to collection logo image

  // Admin
  stable var admins : [Principal] = [
    Principal.fromText("fvuhj-qdha4-tu5gc-4hvim-yaxae-g5grp-xjiz3-u5rpo-5cniw-gpolf-eqe")
  ];

  // Approved operators (for arcade backend canister to transfer)
  stable var approvedOperators : [Principal] = [];

  // Running count of completed transfers (the ICRC-7 transaction index returned by icrc7_transfer).
  stable var transferCount : Nat = 0;

  // In-memory maps
  transient var ownerMap = HashMap.HashMap<Nat, Account>(64, Nat.equal, func(n : Nat) : Hash.Hash { Nat32.fromNat(n % 2147483647) });
  transient var metaMap = HashMap.HashMap<Nat, Metadata>(64, Nat.equal, func(n : Nat) : Hash.Hash { Nat32.fromNat(n % 2147483647) });

  // Rebuild maps from stable storage
  transient let _ : () = do {
    for ((id, acct) in tokenOwners.vals()) { ownerMap.put(id, acct) };
    for ((id, meta) in tokenMetadata.vals()) { metaMap.put(id, meta) };
  };

  func isAdmin(p : Principal) : Bool {
    if (Principal.isAnonymous(p)) return false;
    for (a in admins.vals()) { if (Principal.equal(a, p)) return true };
    Principal.isController(p) // the deploying identity is always admin (it can replace the code anyway)
  };

  func isOperator(p : Principal) : Bool {
    for (o in approvedOperators.vals()) { if (Principal.equal(o, p)) return true };
    false
  };

  // ICRC-7: a missing subaccount and the all-zero 32-byte subaccount are the same account.
  func isDefaultSubaccount(s : ?Blob) : Bool {
    switch (s) {
      case null { true };
      case (?b) { if (b.size() != 32) return false; for (x in b.vals()) { if (x != 0) return false }; true };
    }
  };
  func subaccountsEqual(a : ?Blob, b : ?Blob) : Bool {
    if (isDefaultSubaccount(a)) return isDefaultSubaccount(b);
    a == b
  };
  func accountsEqual(a : Account, b : Account) : Bool {
    Principal.equal(a.owner, b.owner) and subaccountsEqual(a.subaccount, b.subaccount)
  };

  transient let MAX_UPDATE_BATCH : Nat = 100;
  transient let MAX_QUERY_BATCH : Nat = 500;
  transient let MAX_TAKE : Nat = 500;

  // Pre-upgrade: save maps to stable
  system func preupgrade() {
    let ownerBuf = Buffer.Buffer<(Nat, Account)>(ownerMap.size());
    for (entry in ownerMap.entries()) { ownerBuf.add(entry) };
    tokenOwners := Buffer.toArray(ownerBuf);

    let metaBuf = Buffer.Buffer<(Nat, Metadata)>(metaMap.size());
    for (entry in metaMap.entries()) { metaBuf.add(entry) };
    tokenMetadata := Buffer.toArray(metaBuf);
  };

  // ============ ICRC-7 Standard Queries ============

  public shared query func icrc7_collection_metadata() : async Metadata {
    [
      ("icrc7:name", #Text(collectionName)),
      ("icrc7:symbol", #Text(collectionSymbol)),
      ("icrc7:description", #Text(collectionDescription)),
      ("icrc7:total_supply", #Nat(ownerMap.size())),
      ("icrc7:logo", #Text(collectionLogo)),
      ("icrc7:max_query_batch_size", #Nat(MAX_QUERY_BATCH)),
      ("icrc7:max_update_batch_size", #Nat(MAX_UPDATE_BATCH)),
      ("icrc7:default_take_value", #Nat(MAX_TAKE)),
      ("icrc7:max_take_value", #Nat(MAX_TAKE)),
      ("icrc7:max_memo_size", #Nat(256)),
      ("icrc7:atomic_batch_transfers", #Text("true")),
    ]
  };

  public shared query func icrc7_name() : async Text { collectionName };
  public shared query func icrc7_symbol() : async Text { collectionSymbol };
  public shared query func icrc7_description() : async Text { collectionDescription };
  public shared query func icrc7_total_supply() : async Nat { ownerMap.size() };
  public shared query func icrc7_supply_cap() : async ?Nat { null };

  // Logo for marketplace display
  public shared query func icrc7_logo() : async ?Text { ?collectionLogo };

  // Paginated token listing (ascending ids) — marketplaces use this to enumerate all tokens
  public shared query func icrc7_tokens(prev : ?Nat, take : ?Nat) : async [Nat] {
    let limit = switch (take) { case (?t) { if (t > MAX_TAKE) MAX_TAKE else t }; case null { MAX_TAKE } };
    let start = switch (prev) { case (?p) { p + 1 }; case null { 0 } };
    let buf = Buffer.Buffer<Nat>(16);
    var id = start;
    while (id < nextTokenId and buf.size() < limit) {
      switch (ownerMap.get(id)) {
        case (?_) { buf.add(id) };
        case null {}; // deleted/burned token, skip
      };
      id += 1;
    };
    Buffer.toArray(buf)
  };

  // Standard declaration — tells wallets and marketplaces what we support
  public shared query func icrc7_supported_standards() : async [{name : Text; url : Text}] {
    [
      {name = "ICRC-7"; url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-7/ICRC-7.md"},
      {name = "ICRC-10"; url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-10/ICRC-10.md"},
    ]
  };
  public shared query func icrc10_supported_standards() : async [{name : Text; url : Text}] {
    [
      {name = "ICRC-7"; url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-7/ICRC-7.md"},
      {name = "ICRC-10"; url = "https://github.com/dfinity/ICRC/blob/main/ICRCs/ICRC-10/ICRC-10.md"},
    ]
  };

  // Max memo size for transfers
  public shared query func icrc7_max_memo_size() : async ?Nat { ?256 };

  public shared query func icrc7_max_update_batch_size() : async ?Nat { ?MAX_UPDATE_BATCH };
  public shared query func icrc7_max_query_batch_size() : async ?Nat { ?MAX_QUERY_BATCH };
  public shared query func icrc7_default_take_value() : async ?Nat { ?MAX_TAKE };
  public shared query func icrc7_max_take_value() : async ?Nat { ?MAX_TAKE };
  public shared query func icrc7_atomic_batch_transfers() : async ?Bool { ?true };
  public shared query func icrc7_tx_window() : async ?Nat { null };
  public shared query func icrc7_permitted_drift() : async ?Nat { null };

  // ICRC-7 standard lookups: each takes a list and answers in the same order (null = no such token).
  public shared query func icrc7_owner_of(tokenIds : [Nat]) : async [?Account] {
    assert (tokenIds.size() <= MAX_QUERY_BATCH);
    Array.map<Nat, ?Account>(tokenIds, func(id) { ownerMap.get(id) })
  };

  public shared query func icrc7_token_metadata(tokenIds : [Nat]) : async [?Metadata] {
    assert (tokenIds.size() <= MAX_QUERY_BATCH);
    Array.map<Nat, ?Metadata>(tokenIds, func(id) { metaMap.get(id) })
  };

  // Tokens held by an account, ascending, paged with prev/take like icrc7_tokens.
  public shared query func icrc7_tokens_of(account : Account, prev : ?Nat, take : ?Nat) : async [Nat] {
    let limit = switch (take) { case (?t) { if (t > MAX_TAKE) MAX_TAKE else t }; case null { MAX_TAKE } };
    let start = switch (prev) { case (?p) { p + 1 }; case null { 0 } };
    let buf = Buffer.Buffer<Nat>(16);
    var id = start;
    while (id < nextTokenId and buf.size() < limit) {
      switch (ownerMap.get(id)) {
        case (?acct) { if (accountsEqual(acct, account)) { buf.add(id) } };
        case null {};
      };
      id += 1;
    };
    Buffer.toArray(buf)
  };

  public shared query func icrc7_balance_of(accounts : [Account]) : async [Nat] {
    assert (accounts.size() <= MAX_QUERY_BATCH);
    Array.map<Account, Nat>(accounts, func(account) {
      var count : Nat = 0;
      for ((_, acct) in ownerMap.entries()) {
        if (accountsEqual(acct, account)) { count += 1 };
      };
      count
    })
  };

  // ============ ICRC-7 Transfer ============

  // Why one token of a transfer request cannot move (null = it can).
  func transferProblem(caller : Principal, isOperatorCaller : Bool, arg : TransferArg) : ?TransferError {
    switch (ownerMap.get(arg.token_id)) {
      case null { ?#NonExistingTokenId };
      case (?currentOwner) {
        // Caller must be the token's owner or an approved operator (the arcade_backend
        // canister itself, acting as the system). Being a human admin grants NO special
        // transfer bypass here — not even Jay's own admin account can freely move an
        // Official NFT. This is intentional: "not even admin" is the whole point of the
        // closed-loop policy, so admin is bound by the exact same rules as any other owner.
        let isOwner = Principal.equal(caller, currentOwner.owner) and subaccountsEqual(arg.from_subaccount, currentOwner.subaccount);
        if (not isOwner and not isOperatorCaller) return ?#Unauthorized;
        // An operator (the arcade backend) may only move tokens that are IN arcade custody
        // (owned by an operator). It can never pull a token out of a player's wallet.
        if (not isOwner and isOperatorCaller and not isOperator(currentOwner.owner)) return ?#Unauthorized;
        // Closed-loop rule: a plain token owner (including an admin who happens to own a
        // token personally) may only ever send it INTO arcade custody (i.e. to an approved
        // operator) — never to any other wallet or outside marketplace. Operator-initiated
        // transfers (the arcade_backend canister moving a token from its own custody to a
        // redeeming buyer, or back to a delisting seller) are the one exception.
        if (isOwner and not isOperatorCaller and not isOperator(arg.to.owner)) return ?#Unauthorized;
        if (accountsEqual(currentOwner, arg.to)) return ?#InvalidRecipient;
        if (Principal.isAnonymous(arg.to.owner)) return ?#InvalidRecipient;
        null
      };
    }
  };

  /// ICRC-7 standard transfer: one request per token, one answer per request, in order.
  /// Batches are atomic (icrc7_atomic_batch_transfers = true): if any token cannot move, none do.
  public shared(msg) func icrc7_transfer(args : [TransferArg]) : async [?TransferResult] {
    let caller = msg.caller;
    if (args.size() > MAX_UPDATE_BATCH) {
      return Array.map<TransferArg, ?TransferResult>(args, func(_) { ?#Err(#GenericBatchError({ error_code = 1; message = "Too many transfers in one call (max " # Nat.toText(MAX_UPDATE_BATCH) # ")" })) });
    };
    let isOperatorCaller = isOperator(caller);

    // Pass 1: check EVERY token before moving any.
    let problems = Buffer.Buffer<?TransferError>(args.size());
    let seen = Buffer.Buffer<Nat>(args.size());
    var anyProblem = false;
    for (arg in args.vals()) {
      var dup = false;
      for (s in seen.vals()) { if (s == arg.token_id) { dup := true } };
      seen.add(arg.token_id);
      let p : ?TransferError = if (dup) {
        ?#GenericError({ error_code = 2; message = "Token " # Nat.toText(arg.token_id) # " listed twice in one transfer" })
      } else { transferProblem(caller, isOperatorCaller, arg) };
      if (Option.isSome(p)) { anyProblem := true };
      problems.add(p);
    };
    if (anyProblem) {
      return Array.tabulate<?TransferResult>(args.size(), func(i) {
        switch (problems.get(i)) {
          case (?e) { ?#Err(e) };
          case null { ?#Err(#GenericError({ error_code = 3; message = "Not transferred: another token in this batch could not be moved" })) };
        }
      });
    };

    // Pass 2: every token passed, so move them all (no await between passes: nothing can interleave).
    let results = Buffer.Buffer<?TransferResult>(args.size());
    for (arg in args.vals()) {
      ownerMap.put(arg.token_id, arg.to);
      results.add(?#Ok(transferCount));
      transferCount += 1;
    };
    Buffer.toArray(results)
  };

  // ============ Minting (Admin only) ============

  public shared(msg) func mint(to : Account, metadata : Metadata) : async Nat {
    assert(isAdmin(msg.caller) or isOperator(msg.caller));
    let tokenId = nextTokenId;
    nextTokenId += 1;
    ownerMap.put(tokenId, to);
    metaMap.put(tokenId, metadata);
    tokenId
  };

  public shared(msg) func mintBatch(to : Account, metadataList : [Metadata]) : async [Nat] {
    assert(isAdmin(msg.caller) or isOperator(msg.caller));
    let ids = Buffer.Buffer<Nat>(metadataList.size());
    for (meta in metadataList.vals()) {
      let tokenId = nextTokenId;
      nextTokenId += 1;
      ownerMap.put(tokenId, to);
      metaMap.put(tokenId, meta);
      ids.add(tokenId);
    };
    Buffer.toArray(ids)
  };

  // ============ Admin Functions ============

  public shared(msg) func addOperator(operator : Principal) : async () {
    assert(isAdmin(msg.caller));
    let buf = Buffer.Buffer<Principal>(approvedOperators.size() + 1);
    for (o in approvedOperators.vals()) { buf.add(o) };
    buf.add(operator);
    approvedOperators := Buffer.toArray(buf);
  };

  public shared(msg) func removeOperator(operator : Principal) : async () {
    assert(isAdmin(msg.caller));
    approvedOperators := Array.filter<Principal>(approvedOperators, func(o) { not Principal.equal(o, operator) });
  };

  // Admin: set collection logo URL
  public shared(msg) func setCollectionLogo(logo : Text) : async () {
    assert(isAdmin(msg.caller));
    collectionLogo := logo;
  };

  public shared(msg) func addAdmin(admin : Principal) : async () {
    assert(isAdmin(msg.caller));
    let buf = Buffer.Buffer<Principal>(admins.size() + 1);
    for (a in admins.vals()) { buf.add(a) };
    buf.add(admin);
    admins := Buffer.toArray(buf);
  };

  public shared(msg) func setCollectionMetadata(name : Text, symbol : Text, description : Text) : async () {
    assert(isAdmin(msg.caller));
    collectionName := name;
    collectionSymbol := symbol;
    collectionDescription := description;
  };

  // ============ Utility ============

  public shared query func getOperators() : async [Principal] { approvedOperators };
  public shared query func getAdmins() : async [Principal] { admins };
}

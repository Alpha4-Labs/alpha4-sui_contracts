// Copyright (c) Alpha4, Inc.
// SPDX-License-Identifier: MIT

/// @title Alpha ID - Cross-Chain Identity NFT
/// @notice This contract implements a soulbound NFT that serves as a cross-chain
/// identity passport, allowing users to link wallets from multiple blockchains
/// and authorize cross-chain transactions.
module alpha4::alpha_id {
    // === Imports ===
    use sui::object::{Self, UID, ID};
    use sui::event;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use std::string::{Self, String};
    use std::vector;
    use std::option::{Self, Option};

    // === Error Codes ===
    const ENotOwner: u64 = 1;
    const ENotAuthorized: u64 = 2;
    const EAccountAlreadyLinked: u64 = 3;
    const EAccountNotLinked: u64 = 4;
    const EChainNotSupported: u64 = 5;
    const EAddressInvalid: u64 = 6;
    const EInvalidProof: u64 = 7;
    const EAccountAlreadyVerified: u64 = 8;
    const EOperationPaused: u64 = 9;
    const EUnlinkCooldownActive: u64 = 10;
    const ELinkLimitReached: u64 = 11;
    const EInvalidVerifier: u64 = 12;
    const EVerificationExpired: u64 = 13;

    // === Constants ===
    // Maximum number of linked accounts per chain
    const MAX_LINKED_ACCOUNTS_PER_CHAIN: u64 = 3;
    
    // Cooldown period for unlinking accounts (in seconds)
    const UNLINK_COOLDOWN_SECONDS: u64 = 86400; // 24 hours
    
    // Verification expiration time (in seconds)
    const VERIFICATION_EXPIRATION_SECONDS: u64 = 3600; // 1 hour

    // === Types ===
    /// Main Alpha ID NFT - Soulbound to the owner
    struct AlphaID has key, store {
        id: UID,
        /// The owner's address
        owner: address,
        /// When the Alpha ID was created
        created_at: u64,
        /// Metadata for the AlphaID
        metadata: Metadata,
        /// Linked accounts from other chains
        linked_accounts: Table<ChainId, LinkedAccounts>,
        /// Security settings
        security: SecuritySettings,
        /// Flag to indicate if this Alpha ID is active
        active: bool,
    }

    /// Metadata for the Alpha ID
    struct Metadata has store {
        /// User-provided name for this Alpha ID
        name: String,
        /// Description of this Alpha ID
        description: String,
        /// URI to an image or other representation
        image_url: Option<String>,
        /// Additional custom attributes
        attributes: vector<Attribute>,
    }

    /// Custom attributes for the Alpha ID metadata
    struct Attribute has store, copy, drop {
        trait_type: String,
        value: String,
    }

    /// Identifier for blockchain networks
    struct ChainId has store, copy, drop {
        /// Chain identifier (e.g., "ethereum", "solana", "avalanche")
        name: String,
        /// Specific chain ID (e.g., 1 for Ethereum mainnet)
        id: u64,
    }

    /// Collection of linked accounts for a specific chain
    struct LinkedAccounts has store {
        /// Map of accounts by address
        accounts: Table<String, LinkedAccount>,
        /// Count of linked accounts
        count: u64,
    }

    /// Represents a linked external blockchain account
    struct LinkedAccount has store, drop {
        /// Address on the external chain
        address: String,
        /// Whether the account ownership has been verified
        verified: bool,
        /// When the account was linked
        linked_at: u64,
        /// When the account was last verified
        last_verified_at: Option<u64>,
        /// When the account was last used for a cross-chain action
        last_used_at: Option<u64>,
        /// Optional friendly name for this account
        label: Option<String>,
        /// Security level (0=low, 1=medium, 2=high)
        security_level: u8,
        /// When the account can be unlinked (cooldown)
        unlink_available_at: u64,
    }

    /// Security settings for the AlphaID
    struct SecuritySettings has store {
        /// Default security level for new accounts
        default_security_level: u8,
        /// Whether enhanced security is enabled
        enhanced_security_enabled: bool,
        /// Recovery address (optional)
        recovery_address: Option<address>,
        /// Whether to require verification for all operations
        require_verification: bool,
    }

    /// Capability that allows verifiers to validate linked accounts
    struct VerifierCap has key, store {
        id: UID,
        /// The chain this verifier can validate
        chain_id: ChainId,
        /// Address of the verifier
        verifier: address,
        /// Whether this verifier is active
        active: bool,
    }

    /// Admin capability for protocol management
    struct AdminCap has key, store {
        id: UID,
    }

    // === Events ===
    /// Emitted when a new Alpha ID is minted
    struct AlphaIDMinted has copy, drop {
        id: ID,
        owner: address,
        timestamp: u64,
    }

    /// Emitted when an account is linked
    struct AccountLinked has copy, drop {
        alpha_id: ID,
        chain_id: ChainId,
        address: String,
        timestamp: u64,
    }

    /// Emitted when an account is verified
    struct AccountVerified has copy, drop {
        alpha_id: ID,
        chain_id: ChainId,
        address: String,
        verifier: address,
        timestamp: u64,
    }

    /// Emitted when an account is unlinked
    struct AccountUnlinked has copy, drop {
        alpha_id: ID,
        chain_id: ChainId,
        address: String,
        timestamp: u64,
    }

    /// Emitted when a cross-chain action is requested
    struct CrossChainActionRequested has copy, drop {
        alpha_id: ID,
        chain_id: ChainId,
        address: String,
        action_id: u64,
        timestamp: u64,
    }

    // === Function Declarations ===
    // --- Initialization ---
    /// Initialize the contract
    fun init(ctx: &mut TxContext) {
        // Create and transfer admin capability to the deployer
        transfer::transfer(
            AdminCap { id: object::new(ctx) },
            tx_context::sender(ctx)
        );
    }

    // --- Alpha ID Management ---
    /// Mint a new Alpha ID NFT
    /// @param name Name for this Alpha ID
    /// @param description Description of this Alpha ID
    /// @param image_url Optional URL to an image
    /// @param clock The Sui clock object for timestamp
    /// @param ctx Transaction context
    public entry fun mint(
        name: String,
        description: String,
        image_url: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let timestamp = clock::timestamp_ms(clock);
        
        // Create empty metadata with provided info
        let metadata = Metadata {
            name,
            description,
            image_url: if (vector::length(&image_url) > 0) {
                option::some(string::utf8(image_url))
            } else {
                option::none()
            },
            attributes: vector::empty(),
        };
        
        // Create default security settings
        let security = SecuritySettings {
            default_security_level: 1, // Medium security by default
            enhanced_security_enabled: false,
            recovery_address: option::none(),
            require_verification: true,
        };
        
        // Create the Alpha ID
        let alpha_id = AlphaID {
            id: object::new(ctx),
            owner: sender,
            created_at: timestamp,
            metadata,
            linked_accounts: table::new(ctx),
            security,
            active: true,
        };
        
        // Emit event
        event::emit(AlphaIDMinted {
            id: object::id(&alpha_id),
            owner: sender,
            timestamp,
        });
        
        // Transfer as a soulbound NFT to the sender
        transfer::transfer(alpha_id, sender);
    }

    /// Update the Alpha ID metadata
    /// @param alpha_id The Alpha ID to update
    /// @param name New name (empty string to keep current)
    /// @param description New description (empty string to keep current)
    /// @param image_url New image URL (empty vec to keep current)
    /// @param ctx Transaction context
    public entry fun update_metadata(
        alpha_id: &mut AlphaID,
        name: String,
        description: String,
        image_url: vector<u8>,
        ctx: &mut TxContext
    ) {
        // Verify ownership
        let sender = tx_context::sender(ctx);
        assert!(alpha_id.owner == sender, ENotOwner);
        
        // Update fields if provided
        if (!string::is_empty(&name)) {
            alpha_id.metadata.name = name;
        };
        
        if (!string::is_empty(&description)) {
            alpha_id.metadata.description = description;
        };
        
        if (vector::length(&image_url) > 0) {
            alpha_id.metadata.image_url = option::some(string::utf8(image_url));
        };
    }

    /// Add a custom attribute to the Alpha ID
    /// @param alpha_id The Alpha ID to modify
    /// @param trait_type The attribute type
    /// @param value The attribute value
    /// @param ctx Transaction context
    public entry fun add_attribute(
        alpha_id: &mut AlphaID,
        trait_type: String,
        value: String,
        ctx: &mut TxContext
    ) {
        // Verify ownership
        let sender = tx_context::sender(ctx);
        assert!(alpha_id.owner == sender, ENotOwner);
        
        // Add the attribute
        vector::push_back(&mut alpha_id.metadata.attributes, Attribute { 
            trait_type, 
            value 
        });
    }

    // --- Account Linking ---
    /// Link an external account to this Alpha ID
    /// @param alpha_id The Alpha ID to link to
    /// @param chain_name The blockchain name (e.g., "ethereum")
    /// @param chain_id The blockchain ID (e.g., 1 for Ethereum mainnet)
    /// @param address The address on the target chain
    /// @param label Optional friendly name for this account
    /// @param clock The Sui clock object for timestamp
    /// @param ctx Transaction context
    public entry fun link_account(
        alpha_id: &mut AlphaID,
        chain_name: String,
        chain_id_num: u64,
        address: String,
        label: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify ownership and active status
        let sender = tx_context::sender(ctx);
        assert!(alpha_id.owner == sender, ENotOwner);
        assert!(alpha_id.active, EOperationPaused);
        
        // Create chain ID
        let chain_id = ChainId { name: chain_name, id: chain_id_num };
        
        // Validate the address format (simplified validation)
        assert!(!string::is_empty(&address), EAddressInvalid);
        
        // Get the timestamp
        let timestamp = clock::timestamp_ms(clock);
        
        // Get or create linked accounts for this chain
        if (!table::contains(&alpha_id.linked_accounts, chain_id)) {
            table::add(&mut alpha_id.linked_accounts, chain_id, LinkedAccounts {
                accounts: table::new(ctx),
                count: 0,
            });
        };
        
        let linked_accounts = table::borrow_mut(&mut alpha_id.linked_accounts, chain_id);
        
        // Ensure we haven't reached the limit for this chain
        assert!(linked_accounts.count < MAX_LINKED_ACCOUNTS_PER_CHAIN, ELinkLimitReached);
        
        // Ensure this account isn't already linked
        assert!(!table::contains(&linked_accounts.accounts, address), EAccountAlreadyLinked);
        
        // Create the linked account with default values
        let linked_account = LinkedAccount {
            address: address,
            verified: false,
            linked_at: timestamp,
            last_verified_at: option::none(),
            last_used_at: option::none(),
            label: if (vector::length(&label) > 0) {
                option::some(string::utf8(label))
            } else {
                option::none()
            },
            security_level: alpha_id.security.default_security_level,
            unlink_available_at: timestamp, // Can unlink immediately since not verified
        };
        
        // Add the account and update the count
        table::add(&mut linked_accounts.accounts, address, linked_account);
        linked_accounts.count = linked_accounts.count + 1;
        
        // Emit event
        event::emit(AccountLinked {
            alpha_id: object::id(alpha_id),
            chain_id,
            address,
            timestamp,
        });
    }

    /// Verify a linked account (called by an authorized verifier)
    /// @param alpha_id The Alpha ID containing the account
    /// @param chain_name The blockchain name
    /// @param chain_id_num The blockchain ID
    /// @param address The address to verify
    /// @param verifier_cap The verifier capability
    /// @param clock The Sui clock object for timestamp
    /// @param ctx Transaction context
    public entry fun verify_account(
        alpha_id: &mut AlphaID,
        chain_name: String,
        chain_id_num: u64,
        address: String,
        verifier_cap: &VerifierCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Create chain ID
        let chain_id = ChainId { name: chain_name, id: chain_id_num };
        
        // Verify the verifier is active and authorized for this chain
        assert!(verifier_cap.active, ENotAuthorized);
        assert!(verifier_cap.chain_id.name == chain_name, EInvalidVerifier);
        assert!(verifier_cap.chain_id.id == chain_id_num, EInvalidVerifier);
        
        // Get timestamp
        let timestamp = clock::timestamp_ms(clock);
        
        // Ensure the chain exists and the account is linked
        assert!(table::contains(&alpha_id.linked_accounts, chain_id), EChainNotSupported);
        
        let linked_accounts = table::borrow_mut(&mut alpha_id.linked_accounts, chain_id);
        assert!(table::contains(&linked_accounts.accounts, address), EAccountNotLinked);
        
        let linked_account = table::borrow_mut(&mut linked_accounts.accounts, address);
        
        // Skip if already verified
        if (linked_account.verified) {
            return
        };
        
        // Update verification status
        linked_account.verified = true;
        linked_account.last_verified_at = option::some(timestamp);
        
        // Set unlink cooldown
        linked_account.unlink_available_at = timestamp + (UNLINK_COOLDOWN_SECONDS * 1000);
        
        // Emit event
        event::emit(AccountVerified {
            alpha_id: object::id(alpha_id),
            chain_id,
            address,
            verifier: verifier_cap.verifier,
            timestamp,
        });
    }

    /// Unlink an account from this Alpha ID
    /// @param alpha_id The Alpha ID to modify
    /// @param chain_name The blockchain name
    /// @param chain_id_num The blockchain ID
    /// @param address The address to unlink
    /// @param clock The Sui clock object for timestamp
    /// @param ctx Transaction context
    public entry fun unlink_account(
        alpha_id: &mut AlphaID,
        chain_name: String,
        chain_id_num: u64,
        address: String,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify ownership
        let sender = tx_context::sender(ctx);
        assert!(alpha_id.owner == sender, ENotOwner);
        
        // Create chain ID
        let chain_id = ChainId { name: chain_name, id: chain_id_num };
        
        // Get timestamp
        let timestamp = clock::timestamp_ms(clock);
        
        // Ensure the chain and account exist
        assert!(table::contains(&alpha_id.linked_accounts, chain_id), EChainNotSupported);
        
        let linked_accounts = table::borrow_mut(&mut alpha_id.linked_accounts, chain_id);
        assert!(table::contains(&linked_accounts.accounts, address), EAccountNotLinked);
        
        // Check cooldown period for verified accounts
        let linked_account = table::borrow(&linked_accounts.accounts, address);
        assert!(timestamp >= linked_account.unlink_available_at, EUnlinkCooldownActive);
        
        // Remove the account and update the count
        table::remove(&mut linked_accounts.accounts, address);
        linked_accounts.count = linked_accounts.count - 1;
        
        // Emit event
        event::emit(AccountUnlinked {
            alpha_id: object::id(alpha_id),
            chain_id,
            address,
            timestamp,
        });
    }

    // --- Security Settings ---
    /// Update security settings
    /// @param alpha_id The Alpha ID to modify
    /// @param default_level Default security level for new accounts
    /// @param enhanced_security Whether to enable enhanced security
    /// @param recovery_addr Optional recovery address
    /// @param require_verify Whether to require verification for all operations
    /// @param ctx Transaction context
    public entry fun update_security_settings(
        alpha_id: &mut AlphaID,
        default_level: u8,
        enhanced_security: bool,
        recovery_addr: address,
        require_verify: bool,
        ctx: &mut TxContext
    ) {
        // Verify ownership
        let sender = tx_context::sender(ctx);
        assert!(alpha_id.owner == sender, ENotOwner);
        
        // Update security settings
        alpha_id.security.default_security_level = default_level;
        alpha_id.security.enhanced_security_enabled = enhanced_security;
        
        // Only set recovery if not zero address
        if (recovery_addr != @0x0) {
            alpha_id.security.recovery_address = option::some(recovery_addr);
        } else {
            alpha_id.security.recovery_address = option::none();
        };
        
        alpha_id.security.require_verification = require_verify;
    }

    /// Update security level for a specific linked account
    /// @param alpha_id The Alpha ID to modify
    /// @param chain_name The blockchain name
    /// @param chain_id_num The blockchain ID
    /// @param address The linked address
    /// @param security_level New security level
    /// @param ctx Transaction context
    public entry fun update_account_security(
        alpha_id: &mut AlphaID,
        chain_name: String,
        chain_id_num: u64,
        address: String,
        security_level: u8,
        ctx: &mut TxContext
    ) {
        // Verify ownership
        let sender = tx_context::sender(ctx);
        assert!(alpha_id.owner == sender, ENotOwner);
        
        // Create chain ID
        let chain_id = ChainId { name: chain_name, id: chain_id_num };
        
        // Ensure the chain and account exist
        assert!(table::contains(&alpha_id.linked_accounts, chain_id), EChainNotSupported);
        
        let linked_accounts = table::borrow_mut(&mut alpha_id.linked_accounts, chain_id);
        assert!(table::contains(&linked_accounts.accounts, address), EAccountNotLinked);
        
        // Update security level
        let linked_account = table::borrow_mut(&mut linked_accounts.accounts, address);
        linked_account.security_level = security_level;
    }

    // --- Admin Functions ---
    /// Create a new verifier capability
    /// @param chain_name The blockchain name
    /// @param chain_id_num The blockchain ID
    /// @param verifier The address to receive the capability
    /// @param admin_cap The admin capability
    /// @param ctx Transaction context
    public entry fun create_verifier(
        chain_name: String,
        chain_id_num: u64,
        verifier: address,
        _admin_cap: &AdminCap,
        ctx: &mut TxContext
    ) {
        // Create the verifier capability
        let verifier_cap = VerifierCap {
            id: object::new(ctx),
            chain_id: ChainId { name: chain_name, id: chain_id_num },
            verifier: verifier,
            active: true,
        };
        
        // Transfer to the specified verifier
        transfer::transfer(verifier_cap, verifier);
    }

    /// Deactivate a verifier capability
    /// @param verifier_cap The verifier capability to deactivate
    /// @param admin_cap The admin capability
    public entry fun deactivate_verifier(
        verifier_cap: &mut VerifierCap,
        _admin_cap: &AdminCap,
    ) {
        verifier_cap.active = false;
    }

    // --- Cross-Chain Functionality ---
    /// Request a cross-chain action (stub for LayerZero integration)
    /// The actual implementation would use LayerZero's endpoints and include
    /// payload construction and message sending
    /// @param alpha_id The Alpha ID for authorization
    /// @param chain_name The target blockchain name
    /// @param chain_id_num The target blockchain ID
    /// @param address The target address
    /// @param payload The execution payload
    /// @param clock The Sui clock object for timestamp
    /// @param ctx Transaction context
    public entry fun request_cross_chain_action(
        alpha_id: &mut AlphaID,
        chain_name: String,
        chain_id_num: u64,
        address: String,
        payload: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify ownership and active status
        let sender = tx_context::sender(ctx);
        assert!(alpha_id.owner == sender, ENotOwner);
        assert!(alpha_id.active, EOperationPaused);
        
        // Create chain ID
        let chain_id = ChainId { name: chain_name, id: chain_id_num };
        
        // Get timestamp
        let timestamp = clock::timestamp_ms(clock);
        
        // Ensure the chain and account exist
        assert!(table::contains(&alpha_id.linked_accounts, chain_id), EChainNotSupported);
        
        let linked_accounts = table::borrow_mut(&mut alpha_id.linked_accounts, chain_id);
        assert!(table::contains(&linked_accounts.accounts, address), EAccountNotLinked);
        
        // Verify the account if required
        let linked_account = table::borrow_mut(&mut linked_accounts.accounts, address);
        if (alpha_id.security.require_verification) {
            assert!(linked_account.verified, EInvalidProof);
        };
        
        // Update last used timestamp
        linked_account.last_used_at = option::some(timestamp);
        
        // Generate a unique action ID (simplified)
        let action_id = timestamp;
        
        // In a real implementation, this would:
        // 1. Construct the LayerZero message
        // 2. Pay gas fees
        // 3. Send the message via LayerZero's endpoint
        
        // Emit event
        event::emit(CrossChainActionRequested {
            alpha_id: object::id(alpha_id),
            chain_id,
            address,
            action_id,
            timestamp,
        });
        
        // Ignore unused payload for now
        let _ = payload;
    }

    // --- View Functions ---
    /// Check if an account is linked and verified
    /// @param alpha_id The Alpha ID to check
    /// @param chain_name The blockchain name
    /// @param chain_id_num The blockchain ID
    /// @param address The address to check
    /// @return (bool, bool) - (is_linked, is_verified)
    public fun is_account_verified(
        alpha_id: &AlphaID,
        chain_name: String,
        chain_id_num: u64,
        address: String
    ): (bool, bool) {
        let chain_id = ChainId { name: chain_name, id: chain_id_num };
        
        if (!table::contains(&alpha_id.linked_accounts, chain_id)) {
            return (false, false)
        };
        
        let linked_accounts = table::borrow(&alpha_id.linked_accounts, chain_id);
        
        if (!table::contains(&linked_accounts.accounts, address)) {
            return (false, false)
        };
        
        let linked_account = table::borrow(&linked_accounts.accounts, address);
        (true, linked_account.verified)
    }

    /// Get the count of linked accounts for a chain
    /// @param alpha_id The Alpha ID to check
    /// @param chain_name The blockchain name
    /// @param chain_id_num The blockchain ID
    /// @return count of linked accounts
    public fun get_linked_account_count(
        alpha_id: &AlphaID,
        chain_name: String,
        chain_id_num: u64
    ): u64 {
        let chain_id = ChainId { name: chain_name, id: chain_id_num };
        
        if (!table::contains(&alpha_id.linked_accounts, chain_id)) {
            return 0
        };
        
        let linked_accounts = table::borrow(&alpha_id.linked_accounts, chain_id);
        linked_accounts.count
    }

    /// Check if the caller is the owner of the Alpha ID
    /// @param alpha_id The Alpha ID to check
    /// @param addr The address to check
    /// @return true if the address is the owner
    public fun is_owner(alpha_id: &AlphaID, addr: address): bool {
        alpha_id.owner == addr
    }

    // === Test Functions (enabled only for testing) ===
    #[test_only]
    /// Initialize for testing
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }
}
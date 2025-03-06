module TeviVesting::Base {
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, ExtendRef};
    use TeviCoin::TeviCoin;
    use std::simple_map::{Self, SimpleMap};

    /// Errors
    const ENOT_ADMIN: u64 = 1;
    const ENOT_WHITELISTED: u64 = 2;
    const EVESTING_NOT_STARTED: u64 = 3;
    const EVESTING_ALREADY_CLAIMED: u64 = 4;
    const EVESTING_AMOUNT_TOO_HIGH: u64 = 5;
    const EVESTING_CLIFF_NOT_PASSED: u64 = 6;
    const EVESTING_SCHEDULE_INVALID: u64 = 7;
    const EVESTING_ZERO_AMOUNT: u64 = 8;
    const EINSUFFICIENT_BALANCE: u64 = 9;
    const EVESTING_ALREADY_INITIALIZED: u64 = 10;

    /// Constants for time calculations (in seconds)
    const SECONDS_PER_MONTH: u64 = 2592000; // 30 days
    const VESTING_OBJECT_SEED: vector<u8> = b"TEVI_VESTING";
    const BASIS_POINTS_DENOMINATOR: u64 = 10000;

    /// Vesting schedule configuration
    struct VestingSchedule has store, copy, drop {
        cliff_months: u64,
        tge_bps: u64, // Basis points (1/10000)
        linear_vesting_months: u64,
        start_timestamp: u64,
    }

    /// User vesting information
    struct WhitelistedUser has store, copy, drop {
        total_amount: u64,
        claimed_amount: u64,
        last_claim_timestamp: u64,
    }

    /// Main vesting contract storage
    struct VestingContract has key {
        admin: address,
        schedule: VestingSchedule,
        whitelisted_users: SimpleMap<address, WhitelistedUser>,
        token_balance: u64,
        app_extend_ref: ExtendRef,
        start_vesting: u64, // New flag to control vesting start
        
        // Events
        whitelist_events: EventHandle<WhitelistEvent>,
        claim_events: EventHandle<ClaimEvent>,
        deposit_events: EventHandle<DepositEvent>,
    }

    /// Event emitted when a user is whitelisted
    struct WhitelistEvent has drop, store {
        user: address,
        amount: u64,
    }

    /// Event emitted when tokens are claimed
    struct ClaimEvent has drop, store {
        user: address,
        amount: u64,
        timestamp: u64,
    }

    /// Event emitted when tokens are deposited
    struct DepositEvent has drop, store {
        amount: u64,
        timestamp: u64,
    }

    /// Initialize the vesting contract
    public fun initialize(admin: &signer, cliff_months: u64, tge_bps: u64, linear_vesting_months: u64) {
        // Validate parameters
        assert!(tge_bps <= BASIS_POINTS_DENOMINATOR, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(cliff_months > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(linear_vesting_months > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));

        let admin_addr = signer::address_of(admin);
        
        // Create vesting object
        let constructor_ref = object::create_named_object(
            admin,
            VESTING_OBJECT_SEED,
        );
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let vesting_signer = &object::generate_signer(&constructor_ref);
        
        // Create vesting schedule
        let schedule = VestingSchedule {
            cliff_months,
            tge_bps,
            linear_vesting_months,
            start_timestamp: timestamp::now_seconds(),
        };

        // Create vesting contract
        move_to(vesting_signer, VestingContract {
            admin: admin_addr,
            schedule,
            whitelisted_users: simple_map::create<address, WhitelistedUser>(),
            token_balance: 0,
            app_extend_ref: extend_ref,
            start_vesting: 0, // Initialize start_vesting flag to 0
            whitelist_events: account::new_event_handle<WhitelistEvent>(vesting_signer),
            claim_events: account::new_event_handle<ClaimEvent>(vesting_signer),
            deposit_events: account::new_event_handle<DepositEvent>(vesting_signer),
        });

        // Initialize primary store for contract
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(
            signer::address_of(vesting_signer),
            metadata
        );
    }

    /// Get the signer for the vesting contract
    fun get_vesting_signer(): signer acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        object::generate_signer_for_extending(&vesting.app_extend_ref)
    }

    /// Get the vesting contract address
    fun get_vesting_address(): address {
        object::create_object_address(&@TeviVesting, VESTING_OBJECT_SEED)
    }

    /// Deposit tokens into the vesting contract
    public entry fun deposit_tokens(admin: &signer, amount: u64) acquires VestingContract {
        let admin_addr = signer::address_of(admin);
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global_mut<VestingContract>(vesting_addr);
        
        assert!(admin_addr == vesting.admin, error::permission_denied(ENOT_ADMIN));
        assert!(amount > 0, error::invalid_argument(EVESTING_ZERO_AMOUNT));

        // Get TeviCoin metadata and transfer tokens
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::transfer(admin, metadata, vesting_addr, amount);
        vesting.token_balance = vesting.token_balance + amount;

        event::emit_event(&mut vesting.deposit_events, DepositEvent {
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Function to start vesting by setting the start_vesting flag
    public entry fun start_vesting(admin: &signer) acquires VestingContract {
        let admin_addr = signer::address_of(admin);
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global_mut<VestingContract>(vesting_addr);
        
        assert!(admin_addr == vesting.admin, error::permission_denied(ENOT_ADMIN));
        vesting.start_vesting = 1;
    }

    /// Add multiple users to the whitelist in a single transaction
    public entry fun batch_whitelist_users(
        admin: &signer,
        users: vector<address>,
        amounts: vector<u64>,
    ) acquires VestingContract {
        let admin_addr = signer::address_of(admin);
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global_mut<VestingContract>(vesting_addr);
        
        // Validate admin permission
        assert!(admin_addr == vesting.admin, error::permission_denied(ENOT_ADMIN));
        
        // Ensure vesting has not started
        assert!(vesting.start_vesting == 0, error::invalid_state(EVESTING_ALREADY_INITIALIZED));
        
        // Validate vectors have same length
        let users_len = vector::length(&users);
        assert!(users_len == vector::length(&amounts), error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        
        // Calculate total amount to be whitelisted
        let i = 0;
        let total_new_amount = 0u64;
        while (i < users_len) {
            let amount = *vector::borrow(&amounts, i);
            assert!(amount > 0, error::invalid_argument(EVESTING_ZERO_AMOUNT));
            total_new_amount = total_new_amount + amount;
            i = i + 1;
        };
        
        // Check if contract has enough balance
        let total_whitelisted = get_total_whitelisted_amount(vesting) + total_new_amount;
        assert!(vesting.token_balance >= total_whitelisted, error::invalid_state(EINSUFFICIENT_BALANCE));

        // Process all users
        let metadata = TeviCoin::get_metadata();
        i = 0;
        while (i < users_len) {
            let user = *vector::borrow(&users, i);
            let amount = *vector::borrow(&amounts, i);
            
            let user_info = WhitelistedUser {
                total_amount: amount,
                claimed_amount: 0,
                last_claim_timestamp: 0,
            };

            if (simple_map::contains_key(&vesting.whitelisted_users, &user)) {
                *simple_map::borrow_mut(&mut vesting.whitelisted_users, &user) = user_info;
            } else {
                simple_map::add(&mut vesting.whitelisted_users, user, user_info);
            };

            // Ensure user has primary store
            primary_fungible_store::ensure_primary_store_exists(user, metadata);

            event::emit_event(&mut vesting.whitelist_events, WhitelistEvent {
                user,
                amount,
            });

            i = i + 1;
        };
    }

    /// Claim vested tokens
    public entry fun claim(user: &signer) acquires VestingContract {
        let user_addr = signer::address_of(user);
        let vesting_signer = get_vesting_signer();
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global_mut<VestingContract>(vesting_addr);
        
        assert!(simple_map::contains_key(&vesting.whitelisted_users, &user_addr), 
            error::permission_denied(ENOT_WHITELISTED));

        let user_info = simple_map::borrow_mut(&mut vesting.whitelisted_users, &user_addr);
        let current_time = timestamp::now_seconds();
        let schedule_copy = vesting.schedule;
        
        let claimable = calculate_claimable_amount(
            schedule_copy,
            user_info.total_amount,
            user_info.claimed_amount,
            current_time
        );

        assert!(claimable > 0, error::invalid_state(EVESTING_AMOUNT_TOO_HIGH));

        // Update user info
        user_info.claimed_amount = user_info.claimed_amount + claimable;
        user_info.last_claim_timestamp = current_time;
        vesting.token_balance = vesting.token_balance - claimable;

        // Transfer tokens
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::transfer(
            &vesting_signer,
            metadata,
            user_addr,
            claimable
        );

        event::emit_event(&mut vesting.claim_events, ClaimEvent {
            user: user_addr,
            amount: claimable,
            timestamp: current_time,
        });
    }

    /// Calculate the amount of tokens that can be claimed
    fun calculate_claimable_amount(
        schedule: VestingSchedule,
        total_amount: u64,
        claimed_amount: u64,
        current_time: u64,
    ): u64 {
        let time_passed = current_time - schedule.start_timestamp;
        let months_passed = time_passed / SECONDS_PER_MONTH;

        // Check if cliff period has passed
        if (months_passed < schedule.cliff_months) {
            return 0
        };

        // Calculate TGE amount
        let tge_amount = (total_amount as u128) * (schedule.tge_bps as u128) / (BASIS_POINTS_DENOMINATOR as u128);
        let remaining_amount = total_amount - (tge_amount as u64);

        // Calculate linear vesting amount
        let vesting_months = if (months_passed > schedule.cliff_months + schedule.linear_vesting_months) {
            schedule.linear_vesting_months
        } else {
            months_passed - schedule.cliff_months
        };

        let monthly_amount = (remaining_amount as u128) / (schedule.linear_vesting_months as u128);
        let linear_amount = monthly_amount * (vesting_months as u128);

        let total_claimable = tge_amount + linear_amount;
        ((total_claimable as u64) - claimed_amount)
    }

    /// Get total amount of tokens allocated to whitelisted users
    fun get_total_whitelisted_amount(vesting: &VestingContract): u64 {
        let total = 0u64;
        let users = simple_map::keys(&vesting.whitelisted_users);
        let i = 0;
        let len = vector::length(&users);
        while (i < len) {
            let user = *vector::borrow(&users, i);
            let user_info = simple_map::borrow(&vesting.whitelisted_users, &user);
            total = total + user_info.total_amount;
            i = i + 1;
        };
        total
    }

    #[view]
    public fun get_vesting_info(user: address): (u64, u64, u64) acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        if (!simple_map::contains_key(&vesting.whitelisted_users, &user)) {
            return (0, 0, 0)
        };
        
        let user_info = simple_map::borrow(&vesting.whitelisted_users, &user);
        let schedule_copy = vesting.schedule;
        let claimable = calculate_claimable_amount(
            schedule_copy,
            user_info.total_amount,
            user_info.claimed_amount,
            timestamp::now_seconds()
        );
        
        (user_info.total_amount, user_info.claimed_amount, claimable)
    }

    #[view]
    public fun get_contract_balance(): u64 acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        vesting.token_balance
    }

    #[view]
    public fun get_vesting_schedule(): VestingSchedule acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        vesting.schedule
    }

    #[test_only]
    public fun initialize_for_testing(admin: &signer) {
        // Initialize TeviCoin first
        initialize_for_test(admin);
        // Then initialize vesting contract
        initialize(admin, 6, 1000, 36); // 6 months cliff, 10% TGE, 36 months linear
    }

    #[test_only]
    use aptos_framework::account::create_account_for_test;
    #[test_only]
    use aptos_framework::fungible_asset::{MintRef, BurnRef};
    #[test_only]
    use TeviCoin::TeviCoin::initialize_for_test;

    #[test_only]
    struct TestCapabilities has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
    }

    #[test_only]
    const TEST_CLIFF_MONTHS: u64 = 6;
    #[test_only]
    const TEST_TGE_BPS: u64 = 1000; // 10%
    #[test_only]
    const TEST_LINEAR_MONTHS: u64 = 36;
    #[test_only]
    const TEST_AMOUNT: u64 = 1000000000; // 1 billion tokens
    #[test_only]
    const MONTH_IN_SECONDS: u64 = 2592000; // 30 days

    #[test_only]
    fun setup_test(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        // Initialize all accounts first
        timestamp::set_time_has_started_for_testing(aptos);

        // Create accounts if they don't exist
        if (!account::exists_at(signer::address_of(admin))) {
            create_account_for_test(signer::address_of(admin));
        };
        if (!account::exists_at(signer::address_of(user))) {
            create_account_for_test(signer::address_of(user));
        };
        if (!account::exists_at(get_vesting_address())) {
            create_account_for_test(get_vesting_address());
        };

        // Initialize TeviCoin first
        initialize_for_test(admin);

        // Initialize vesting contract
        initialize(admin, TEST_CLIFF_MONTHS, TEST_TGE_BPS, TEST_LINEAR_MONTHS);

        // Create primary store for admin
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(admin), metadata);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test deposit and whitelist functionality
    fun test_deposit_and_whitelist(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT);

        // Check contract balance
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        assert!(vesting.token_balance == TEST_AMOUNT, 1);

        // Whitelist user
        let user_amount = TEST_AMOUNT / 2;
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(user_amount);
        batch_whitelist_users(admin, users, amounts);

        // Check whitelist info
        let (total, claimed, _) = get_vesting_info(signer::address_of(user));
        assert!(total == user_amount, 2);
        assert!(claimed == 0, 3);

        // Start vesting
        start_vesting(admin);
        
        // Verify vesting has started
        let vesting = borrow_global<VestingContract>(vesting_addr);
        assert!(vesting.start_vesting == 1, 4);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test initialization with valid parameters
    fun test_initialize_valid(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        // Initialize all accounts first
        timestamp::set_time_has_started_for_testing(aptos);

        // Create accounts if they don't exist
        if (!account::exists_at(signer::address_of(admin))) {
            create_account_for_test(signer::address_of(admin));
        };
        if (!account::exists_at(signer::address_of(user))) {
            create_account_for_test(signer::address_of(user));
        };
        
        // Create vesting contract account
        let vesting_addr = get_vesting_address();
        if (!account::exists_at(vesting_addr)) {
            create_account_for_test(vesting_addr);
        };

        // Initialize TeviCoin first
        initialize_for_test(admin);

        // Initialize vesting contract
        initialize(admin, TEST_CLIFF_MONTHS, TEST_TGE_BPS, TEST_LINEAR_MONTHS);

        // Verify contract state
        let vesting = borrow_global<VestingContract>(vesting_addr);
        assert!(vesting.admin == signer::address_of(admin), 0);
        assert!(vesting.schedule.cliff_months == TEST_CLIFF_MONTHS, 1);
        assert!(vesting.schedule.tge_bps == TEST_TGE_BPS, 2);
        assert!(vesting.schedule.linear_vesting_months == TEST_LINEAR_MONTHS, 3);
        assert!(vesting.token_balance == 0, 4);
        assert!(vesting.start_vesting == 0, 5); // Check start_vesting flag is 0
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test claiming after TGE
    fun test_claim_after_tge(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        batch_whitelist_users(admin, users, amounts);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // Claim tokens
        claim(user);

        // Check claimed amount (should be TGE amount)
        let (_, claimed, _) = get_vesting_info(signer::address_of(user));
        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (BASIS_POINTS_DENOMINATOR as u128);
        assert!(claimed == (expected_tge as u64), 1);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test claiming after full vesting period
    fun test_claim_after_full_vesting(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        batch_whitelist_users(admin, users, amounts);

        // Move time to after full vesting period
        timestamp::fast_forward_seconds((TEST_CLIFF_MONTHS + TEST_LINEAR_MONTHS) * MONTH_IN_SECONDS);

        // Claim tokens
        claim(user);

        // Check claimed amount (should be full amount)
        let (total, claimed, _) = get_vesting_info(signer::address_of(user));
        assert!(claimed == total, 1);
        assert!(claimed == TEST_AMOUNT, 2);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 327681, location=TeviVesting::Base)]
    /// Test unauthorized deposit
    fun test_unauthorized_deposit(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint tokens to user (so they have something to deposit)
        TeviCoin::mint(admin, signer::address_of(user), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Try unauthorized deposit (should fail)
        deposit_tokens(user, TEST_AMOUNT);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 327682, location=TeviVesting::Base)]
    /// Test claim by non-whitelisted user
    fun test_claim_not_whitelisted(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);
        claim(user); // Should fail as user is not whitelisted
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 196613, location=TeviVesting::Base)]
    /// Test claim before cliff period
    fun test_claim_before_cliff(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint and deposit tokens
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);
        deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        batch_whitelist_users(admin, users, amounts);

        // Try to claim before cliff period
        claim(user); // Should fail
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test multiple claims during linear vesting period
    fun test_multiple_claims_during_vesting(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        batch_whitelist_users(admin, users, amounts);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // First claim (TGE amount)
        claim(user);
        let (_, claimed_after_tge, _) = get_vesting_info(signer::address_of(user));
        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (BASIS_POINTS_DENOMINATOR as u128);
        assert!(claimed_after_tge == (expected_tge as u64), 1);

        // Move time 6 months into linear vesting
        timestamp::fast_forward_seconds(6 * MONTH_IN_SECONDS);

        // Second claim
        claim(user);
        let (_, claimed_after_6_months, _) = get_vesting_info(signer::address_of(user));
        assert!(claimed_after_6_months > claimed_after_tge, 2);

        // Move time to end of vesting
        timestamp::fast_forward_seconds(30 * MONTH_IN_SECONDS);

        // Final claim
        claim(user);
        let (total, claimed_final, _) = get_vesting_info(signer::address_of(user));
        assert!(claimed_final == total, 3);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123, user2 = @0x456)]
    /// Test multiple users vesting
    fun test_multiple_users_vesting(
        aptos: &signer,
        admin: &signer,
        user: &signer,
        user2: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Create account for user2
        if (!account::exists_at(signer::address_of(user2))) {
            create_account_for_test(signer::address_of(user2));
        };

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT * 2);

        // Create primary store for users
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user2), metadata);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT * 2);

        // Whitelist users with different amounts
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();
        
        vector::push_back(&mut users, signer::address_of(user));
        vector::push_back(&mut users, signer::address_of(user2));
        
        vector::push_back(&mut amounts, TEST_AMOUNT);
        vector::push_back(&mut amounts, TEST_AMOUNT);
        
        batch_whitelist_users(admin, users, amounts);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // Both users claim
        claim(user);
        claim(user2);

        // Verify both users received TGE amount
        let (_, claimed1, _) = get_vesting_info(signer::address_of(user));
        let (_, claimed2, _) = get_vesting_info(signer::address_of(user2));
        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (BASIS_POINTS_DENOMINATOR as u128);
        assert!(claimed1 == (expected_tge as u64), 1);
        assert!(claimed2 == (expected_tge as u64), 2);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 196613, location=TeviVesting::Base)]
    /// Test claim with zero claimable amount
    fun test_claim_zero_amount(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        batch_whitelist_users(admin, users, amounts);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // First claim
        claim(user);

        // Try to claim again immediately (should fail as no new tokens are vested)
        claim(user);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 196617, location=TeviVesting::Base)]
    /// Test insufficient balance for whitelist
    fun test_insufficient_balance_whitelist(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint and deposit small amount
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT / 2);
        deposit_tokens(admin, TEST_AMOUNT / 2);

        // Try to whitelist more than available balance
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        batch_whitelist_users(admin, users, amounts);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 196618, location=TeviVesting::Base)]
    /// Test whitelisting after vesting has started
    fun test_whitelist_after_vesting_started(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT);

        // Start vesting
        start_vesting(admin);

        // Attempt to whitelist after vesting has started (should fail)
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        batch_whitelist_users(admin, users, amounts);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123, user2 = @0x456, user3 = @0x789)]
    /// Test batch whitelist functionality
    fun test_batch_whitelist(
        aptos: &signer,
        admin: &signer,
        user: &signer,
        user2: &signer,
        user3: &signer,
    ) acquires VestingContract {
        setup_test(aptos, admin, user);

        // Create accounts for additional users
        if (!account::exists_at(signer::address_of(user2))) {
            create_account_for_test(signer::address_of(user2));
        };
        if (!account::exists_at(signer::address_of(user3))) {
            create_account_for_test(signer::address_of(user3));
        };

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT * 3);

        // Create primary store for users
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user2), metadata);
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user3), metadata);

        // Deposit tokens
        deposit_tokens(admin, TEST_AMOUNT * 3);

        // Create vectors for batch whitelist
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();
        
        vector::push_back(&mut users, signer::address_of(user));
        vector::push_back(&mut users, signer::address_of(user2));
        vector::push_back(&mut users, signer::address_of(user3));
        
        vector::push_back(&mut amounts, TEST_AMOUNT);
        vector::push_back(&mut amounts, TEST_AMOUNT);
        vector::push_back(&mut amounts, TEST_AMOUNT);

        // Batch whitelist users
        batch_whitelist_users(admin, users, amounts);

        // Verify all users are whitelisted with correct amounts
        let (total1, claimed1, _) = get_vesting_info(signer::address_of(user));
        let (total2, claimed2, _) = get_vesting_info(signer::address_of(user2));
        let (total3, claimed3, _) = get_vesting_info(signer::address_of(user3));

        assert!(total1 == TEST_AMOUNT, 1);
        assert!(total2 == TEST_AMOUNT, 2);
        assert!(total3 == TEST_AMOUNT, 3);
        assert!(claimed1 == 0, 4);
        assert!(claimed2 == 0, 5);
        assert!(claimed3 == 0, 6);

        // Move time to after cliff period and verify all users can claim
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        claim(user);
        claim(user2);
        claim(user3);

        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (BASIS_POINTS_DENOMINATOR as u128);
        let (_, claimed1_after, _) = get_vesting_info(signer::address_of(user));
        let (_, claimed2_after, _) = get_vesting_info(signer::address_of(user2));
        let (_, claimed3_after, _) = get_vesting_info(signer::address_of(user3));

        assert!(claimed1_after == (expected_tge as u64), 7);
        assert!(claimed2_after == (expected_tge as u64), 8);
        assert!(claimed3_after == (expected_tge as u64), 9);
    }
}
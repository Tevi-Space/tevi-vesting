module TeviVesting::PrivateInvestor {
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

    /// Constants specific to Private Investor vesting
    const CLIFF_MONTHS: u64 = 3;
    const TGE_BPS: u64 = 1000; // 10%
    const LINEAR_VESTING_MONTHS: u64 = 36;

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
    const VESTING_OBJECT_SEED: vector<u8> = b"TEVI_VESTING_PRIVATE_INVESTOR";
    const BASIS_POINTS_DENOMINATOR: u64 = 10000;

    /// Vesting schedule configuration
    struct VestingSchedule has store, copy, drop {
        cliff_months: u64,
        tge_bps: u64,
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

    /// Initialize the private investor vesting contract
    public entry fun initialize(admin: &signer) {
        // Validate parameters
        assert!(TGE_BPS <= BASIS_POINTS_DENOMINATOR, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(CLIFF_MONTHS > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(LINEAR_VESTING_MONTHS > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));

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
            cliff_months: CLIFF_MONTHS,
            tge_bps: TGE_BPS,
            linear_vesting_months: LINEAR_VESTING_MONTHS,
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
} 
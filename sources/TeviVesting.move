/**
@title Tevi Token Vesting Contract
@dev A flexible token vesting system for any fungible asset on Aptos

This module implements a configurable vesting contract that allows:
- Token vesting with customizable schedules
- Initial token release at TGE (Token Generation Event)
- Cliff period before linear vesting begins
- Linear vesting over a specified period
- Batch whitelisting of users with individual allocation amounts
- Secure token claiming by whitelisted users
- Admin controls for depositing tokens and starting the vesting process
- Configurable asset type - can be used with any Aptos fungible asset

The vesting schedule consists of:
1. Initial release: Optional percentage of tokens released at TGE (basis points)
2. Cliff period: Time period (in months) during which no additional tokens vest
3. Linear vesting: Period (in months) during which remaining tokens vest linearly

Users can only claim tokens according to the vesting schedule, and
the admin must whitelist users and deposit sufficient tokens before
the vesting can be started.
**/
module TeviVesting::Base {
    use std::error;
    use std::signer;
    use std::vector;
    use std::simple_map::{Self, SimpleMap};
    // use std::string;
    // use aptos_std::debug;
    
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::fungible_asset::Metadata;
    use std::option::{Self, Option};

    /// Errors
    const ENOT_ADMIN: u64 = 1;
    const ENOT_WHITELISTED: u64 = 2;
    const EVESTING_AMOUNT_TOO_HIGH: u64 = 5;
    const EVESTING_SCHEDULE_INVALID: u64 = 7;
    const EVESTING_ZERO_AMOUNT: u64 = 8;
    const EINSUFFICIENT_BALANCE: u64 = 9;
    const EVESTING_ALREADY_STARTED: u64 = 11;
    const EASSET_TYPE_NOT_CONFIGURED: u64 = 12;

    /// Constants for time calculations (in seconds)
    const SECONDS_PER_MONTH: u64 = 2592000; // 30 days (default value)
    const VESTING_OBJECT_SEED: vector<u8> = b"TEVI_VESTING";
    const BASIS_POINTS_DENOMINATOR: u64 = 10000;

    /// Vesting schedule configuration
    struct VestingSchedule has store, copy, drop {
        cliff_months: u64,
        tge_bps: u64, // Basis points (1/10000)
        linear_vesting_months: u64,
        start_timestamp: u64,
        seconds_per_month: u64, // Added configurable seconds per month
    }

    /// User vesting information
    struct WhitelistedUser has store, copy, drop {
        total_amount: u64,
        claimed_amount: u64,
        last_claim_timestamp: u64,
        is_pause: bool, // New attribute to control pausing of individual users
    }

    /// Main vesting contract storage
    struct VestingContract has key {
        schedule: VestingSchedule,
        whitelisted_users: SimpleMap<address, WhitelistedUser>,
        token_balance: u64,
        app_extend_ref: ExtendRef,
        start_vesting: u64, // flag to control vesting start
        asset_type: Option<Object<Metadata>>, // Asset to be used for vesting
        is_asset_configured: bool, // Flag to indicate if asset has been configured
    }

    #[event]
    struct ConfigureVestingEvent has drop, store {
        cliff_months: u64,
        tge_bps: u64,
        linear_vesting_months: u64,
        asset_type: address,
        start_timestamp: u64,
        seconds_per_month: u64,
    }

    #[event]
    struct DepositTokensEvent has drop, store {
        amount: u64,
        admin: address,
    }

    #[event]
    struct StartVestingEvent has drop, store {
        admin: address,
        timestamp: u64,
    }

    #[event]
    struct WhitelistUsersEvent has drop, store {
        users: vector<address>,
        amounts: vector<u64>,
        admin: address,
    }
    
    #[event]
    struct ClaimEvent has drop, store {
        user: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct PauseUserEvent has drop, store {
        user: address,
        admin: address,
        timestamp: u64,
    }

    #[event]
    struct UnpauseUserEvent has drop, store {
        user: address,
        admin: address,
        timestamp: u64,
    }

    /// Get the signer for the vesting contract
    fun get_vesting_signer(): signer acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        object::generate_signer_for_extending(&vesting.app_extend_ref)
    }

    /// Get the vesting contract address
    public fun get_vesting_address(): address {
        object::create_object_address(&@TeviVesting, VESTING_OBJECT_SEED)
    }

    /// Borrow the immutable reference of the vesting contract.
    inline fun authorized_borrow_contract(
        owner: &signer
    ): &VestingContract acquires VestingContract {
        let vesting_addr = get_vesting_address();
        assert_is_admin(owner);
        borrow_global<VestingContract>(vesting_addr)
    }

    /// Borrow the mutable reference of the vesting contract.
    inline fun authorized_borrow_contract_mut(
        owner: &signer
    ): &mut VestingContract acquires VestingContract {
        let vesting_addr = get_vesting_address();
        assert_is_admin(owner);
        borrow_global_mut<VestingContract>(vesting_addr)
    }

    /// Check if the signer is the admin and abort if not
    fun assert_is_admin(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        let vesting_addr = get_vesting_address();
        
        // Use object ownership to check admin privileges instead of a stored admin field
        assert!(object::is_owner(object::address_to_object<VestingContract>(vesting_addr), admin_addr), 
            error::permission_denied(ENOT_ADMIN));
        // debug::print(&string::utf8(b"assert_is_admin"));
    }

    /// Initialize the vesting contract on module publish
    fun init_module(admin: &signer) {
        // Create the vesting object using the compatible function with get_vesting_address
        let constructor_ref = &object::create_named_object(admin, VESTING_OBJECT_SEED);
        let extend_ref = object::generate_extend_ref(constructor_ref);
        
        // Get the vesting signer
        let vesting_signer = object::generate_signer(constructor_ref);
        // Initialize the VestingContract with default values
        let default_schedule = VestingSchedule {
            cliff_months: 0,
            tge_bps: 0,
            linear_vesting_months: 0,
            start_timestamp: 0,
            seconds_per_month: SECONDS_PER_MONTH, // Use the default value
        };
        
        // Create an empty SimpleMap for whitelisted users
        let whitelisted_users = simple_map::create<address, WhitelistedUser>();
        
        // Initialize the VestingContract struct and move it to the vesting object's address
        move_to(&vesting_signer, VestingContract {
            schedule: default_schedule,
            whitelisted_users: whitelisted_users,
            token_balance: 0,
            app_extend_ref: extend_ref,
            start_vesting: 0,
            asset_type: option::none(),
            is_asset_configured: false,
        });
    }

    /// Configure vesting parameters
    public entry fun configure_vesting(
        admin: &signer, 
        cliff_months: u64, 
        tge_bps: u64, 
        linear_vesting_months: u64,
        asset_type: address,
        start_timestamp: u64,
        seconds_per_month: u64,
    ) acquires VestingContract {
        let vesting_signer = get_vesting_signer();
        let vesting = authorized_borrow_contract_mut(admin);
        
        // Validate state
        assert!(vesting.start_vesting == 0, error::invalid_state(EVESTING_ALREADY_STARTED));
        
        // Validate parameters
        assert!(tge_bps <= BASIS_POINTS_DENOMINATOR, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(cliff_months > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(linear_vesting_months > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(seconds_per_month > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));
        assert!(start_timestamp > 0, error::invalid_argument(EVESTING_SCHEDULE_INVALID));

        // Update schedule
        vesting.schedule = VestingSchedule {
            cliff_months,
            tge_bps,
            linear_vesting_months,
            start_timestamp,
            seconds_per_month,
        };

        // Update asset type
        let new_asset_type = object::address_to_object<Metadata>(asset_type);
        vesting.asset_type = option::some(new_asset_type);
        vesting.is_asset_configured = true;

        // Ensure primary store exists for the new asset type
        primary_fungible_store::ensure_primary_store_exists(
            signer::address_of(&vesting_signer),
            new_asset_type
        );
        
        // Emit configure event
        event::emit(ConfigureVestingEvent {
            cliff_months,
            tge_bps,
            linear_vesting_months,
            asset_type,
            start_timestamp,
            seconds_per_month,
        });
    }

    /// Returns the active asset metadata object
    fun get_asset_metadata(): Object<Metadata> acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        assert!(vesting.is_asset_configured, error::not_found(EASSET_TYPE_NOT_CONFIGURED));
        *option::borrow(&vesting.asset_type)
    }

    /// Deposit tokens into the vesting contract
    public entry fun deposit_tokens(admin: &signer, amount: u64) acquires VestingContract {
        // Use authorized_borrow_contract_mut instead of assert_is_admin
        let vesting = authorized_borrow_contract_mut(admin);
        let vesting_addr = get_vesting_address();
        let admin_addr = signer::address_of(admin);
        
        assert!(amount > 0, error::invalid_argument(EVESTING_ZERO_AMOUNT));
        assert!(vesting.is_asset_configured, error::not_found(EASSET_TYPE_NOT_CONFIGURED));

        // Get asset metadata and transfer tokens
        let metadata = *option::borrow(&vesting.asset_type);
        primary_fungible_store::transfer(admin, metadata, vesting_addr, amount);
        vesting.token_balance = vesting.token_balance + amount;
        
        // Emit deposit event
        event::emit(DepositTokensEvent {
            amount,
            admin: admin_addr,
        });
    }

    /// Function to start vesting by setting the start_vesting flag
    public entry fun start_vesting(admin: &signer) acquires VestingContract {
        let vesting = authorized_borrow_contract_mut(admin);
        let admin_addr = signer::address_of(admin);
        
        // Ensure vesting has not started
        assert!(vesting.start_vesting == 0, error::invalid_state(EVESTING_ALREADY_STARTED));
        assert!(vesting.is_asset_configured, error::not_found(EASSET_TYPE_NOT_CONFIGURED));
        
        // Check if contract has enough balance
        let total_whitelisted = get_total_whitelisted_amount(vesting);
        assert!(vesting.token_balance >= total_whitelisted, error::invalid_state(EINSUFFICIENT_BALANCE));
        vesting.start_vesting = 1;
        
        // Emit start vesting event
        event::emit(StartVestingEvent {
            admin: admin_addr,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Add multiple users to the whitelist in a single transaction
    public entry fun batch_whitelist_users(
        admin: &signer,
        users: vector<address>,
        amounts: vector<u64>,
    ) acquires VestingContract {
        let vesting = authorized_borrow_contract_mut(admin);
        let admin_addr = signer::address_of(admin);

        // Validate vectors have same length
        let users_len = vector::length(&users);
        assert!(users_len == vector::length(&amounts), error::invalid_argument(EVESTING_SCHEDULE_INVALID));

        // Process all users
        let metadata = *option::borrow(&vesting.asset_type);
        let i = 0;
        while (i < users_len) {
            let user = *vector::borrow(&users, i);
            let amount = *vector::borrow(&amounts, i);
            
            let user_info = WhitelistedUser {
                total_amount: amount,
                claimed_amount: 0,
                last_claim_timestamp: 0,
                is_pause: false, // Default value is false
            };

            if (simple_map::contains_key(&vesting.whitelisted_users, &user)) {
                *simple_map::borrow_mut(&mut vesting.whitelisted_users, &user) = user_info;
            } else {
                simple_map::add(&mut vesting.whitelisted_users, user, user_info);
            };

            // Ensure user has primary store
            primary_fungible_store::ensure_primary_store_exists(user, metadata);
            i = i + 1;
        };
        
        // Emit whitelist users event
        event::emit(WhitelistUsersEvent {
            users,
            amounts,
            admin: admin_addr,
        });
    }

    /// Claim vested tokens
    public entry fun claim(user: &signer) acquires VestingContract {
        let user_addr = signer::address_of(user);
        let vesting_addr = get_vesting_address();
        
        {
            let vesting = borrow_global<VestingContract>(vesting_addr);
            assert!(vesting.is_asset_configured, error::not_found(EASSET_TYPE_NOT_CONFIGURED));
            assert!(simple_map::contains_key(&vesting.whitelisted_users, &user_addr), 
                error::permission_denied(ENOT_WHITELISTED));
            
            // Check if user is paused before allowing claim
            let user_info = simple_map::borrow(&vesting.whitelisted_users, &user_addr);
            assert!(!user_info.is_pause, error::permission_denied(ENOT_WHITELISTED));
        };
        
        let vesting_signer = get_vesting_signer();
        
        let vesting = borrow_global_mut<VestingContract>(vesting_addr);
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
        
        let metadata = *option::borrow(&vesting.asset_type);
        
        // Transfer tokens using primary_fungible_store::transfer directly
        primary_fungible_store::transfer(
            &vesting_signer,
            metadata,
            user_addr,
            claimable
        );
        
        // Emit claim event
        event::emit(ClaimEvent {
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
        if (schedule.start_timestamp == 0 || current_time <= schedule.start_timestamp) {
            return 0
        };

        let time_passed = current_time - schedule.start_timestamp;
        let months_passed = time_passed / schedule.seconds_per_month; // Use the configurable seconds_per_month

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

        // Check if this is the last vesting period and add any remaining tokens due to integer division
        if (vesting_months == schedule.linear_vesting_months) {
            // Calculate exact amount from integer division to ensure all tokens are distributed
            let distributed = (monthly_amount * (schedule.linear_vesting_months as u128));
            let remainder = (remaining_amount as u128) - distributed;
            linear_amount = linear_amount + remainder;
        };

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
    public fun get_vesting_info(user: address): (u64, u64, u64, u64, bool) acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        if (!vesting.is_asset_configured || !simple_map::contains_key(&vesting.whitelisted_users, &user)) {
            return (0, 0, 0, 0, false)
        };
        
        let user_info = simple_map::borrow(&vesting.whitelisted_users, &user);
        let schedule_copy = vesting.schedule;
        let current_time = timestamp::now_seconds();
        let claimable = calculate_claimable_amount(
            schedule_copy,
            user_info.total_amount,
            user_info.claimed_amount,
            current_time
        );
        
        (user_info.total_amount, user_info.claimed_amount, claimable, user_info.last_claim_timestamp, user_info.is_pause)
    }

    #[view]
    public fun get_next_unlock_time(): u64 acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        
        // Return 0 if vesting is not configured
        if (!vesting.is_asset_configured) {
            return 0
        };
        
        // Return 0 if vesting has not started
        if (vesting.start_vesting == 0) {
            return 0
        };
        
        let schedule = vesting.schedule;
        let current_time = timestamp::now_seconds();
        let first_unlock_time = schedule.start_timestamp + (schedule.cliff_months * schedule.seconds_per_month);

        if (current_time < first_unlock_time) {
            return first_unlock_time
        };
        
        // Calculate time passed since vesting started
        let time_passed = current_time - schedule.start_timestamp;
        let months_passed = time_passed / schedule.seconds_per_month;
        
        // If we're before the cliff, next unlock is at cliff end
        if (months_passed < schedule.cliff_months) {
            return first_unlock_time
        };
        
        // If we've passed the cliff but are still in the linear vesting period
        if (months_passed < schedule.cliff_months + schedule.linear_vesting_months) {
            // Calculate the next month's unlock time
            let next_month = months_passed + 1;
            return schedule.start_timestamp + (next_month * schedule.seconds_per_month)
        };
        
        // If we've passed the entire vesting period, there's no next unlock
        return 0
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

    #[view]
    public fun get_vesting_config(): (u64, u64, u64, address, bool, bool, u64) acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        let asset_address = if (vesting.is_asset_configured) {
            object::object_address(option::borrow(&vesting.asset_type))
        } else {
            @0x0
        };
        
        (
            vesting.schedule.cliff_months,
            vesting.schedule.tge_bps,
            vesting.schedule.linear_vesting_months,
            asset_address,
            vesting.is_asset_configured,
            vesting.start_vesting == 1,
            vesting.schedule.seconds_per_month,
        )
    }

    #[view]
    public fun is_vesting_started(): bool acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        vesting.start_vesting == 1
    }

    #[view]
    /// Returns two vectors: one containing all whitelisted user addresses and another containing their corresponding token amounts
    public fun get_whitelisted_users(): (vector<address>, vector<u64>) acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        
        let user_addresses = simple_map::keys(&vesting.whitelisted_users);
        let token_amounts = vector::empty<u64>();
        
        let i = 0;
        let len = vector::length(&user_addresses);
        while (i < len) {
            let user_addr = *vector::borrow(&user_addresses, i);
            let user_info = simple_map::borrow(&vesting.whitelisted_users, &user_addr);
            vector::push_back(&mut token_amounts, user_info.total_amount);
            i = i + 1;
        };
        
        (user_addresses, token_amounts)
    }

    #[view]
    public fun get_amount_need_deposit(): u64 acquires VestingContract {
        let vesting_addr = get_vesting_address();
        let vesting = borrow_global<VestingContract>(vesting_addr);
        
        if (!vesting.is_asset_configured) {
            return 0
        };
        
        let total_whitelisted = get_total_whitelisted_amount(vesting);
        let total_deposited = vesting.token_balance;
        if (total_deposited >= total_whitelisted) {
            return 0
        };
        total_whitelisted - total_deposited
    }

    /// Set a user's pause status (true to pause, false to unpause)
    public entry fun set_user_pause_status(admin: &signer, user: address, is_pause: bool) acquires VestingContract {
        let vesting = authorized_borrow_contract_mut(admin);
        let admin_addr = signer::address_of(admin);
        
        assert!(simple_map::contains_key(&vesting.whitelisted_users, &user), 
            error::permission_denied(ENOT_WHITELISTED));
        
        let user_info = simple_map::borrow_mut(&mut vesting.whitelisted_users, &user);
        user_info.is_pause = is_pause;
        
        // Emit appropriate event based on the pause status
        if (is_pause) {
            event::emit(PauseUserEvent {
                user,
                admin: admin_addr,
                timestamp: timestamp::now_seconds(),
            });
        } else {
            event::emit(UnpauseUserEvent {
                user,
                admin: admin_addr,
                timestamp: timestamp::now_seconds(),
            });
        };
    }

    #[test_only]
    /// Helper function to setup a test environment and return common test values
    public fun initialize_for_test(creator: &signer) {
        init_module(creator);
    }
}
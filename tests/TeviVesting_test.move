#[test_only]
module TeviVesting::BaseTests {
    use std::signer;
    use std::vector;
    // use std::string;
    // use aptos_std::debug;
    
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    
    use TeviCoin::TeviCoin;
    use TeviVesting::Base;

    // Test constants
    const CLIFF_MONTHS: u64 = 3;
    const TGE_BPS: u64 = 1000; // 10% at TGE (10% = 1000 basis points)
    const LINEAR_VESTING_MONTHS: u64 = 12;
    const SECONDS_PER_MONTH: u64 = 2592000; // 30 days
    const TEVI_DECIMALS: u64 = 100000000;
    const START_TIMESTAMP: u64 = 1000; // Starting timestamp for vesting
    const BASIS_POINTS_DENOMINATOR: u64 = 10000; // 100% = 10000 basis points

    // Helper functions 
    fun setup_test_environment(admin: &signer, aptos: &signer) {
        // Create test accounts
        timestamp::set_time_has_started_for_testing(aptos);
        
        // Initialize TeviCoin (needed for vesting)
        TeviCoin::initialize_for_test(admin);

        // Initialize VestingExtendRef
        Base::initialize_for_test(admin);
    }
    
    fun configure_vesting(admin: &signer) {
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        Base::configure_vesting(
            admin, 
            CLIFF_MONTHS, 
            TGE_BPS, 
            LINEAR_VESTING_MONTHS, 
            asset_addr,
            START_TIMESTAMP,
            SECONDS_PER_MONTH
        );
    }
    
    fun mint_and_deposit(admin: &signer, amount: u64) {
        let admin_addr = signer::address_of(admin);
        TeviCoin::mint(admin, admin_addr, amount);
        Base::deposit_tokens(admin, amount);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user1 = @0x456)]
    public fun test_vesting_init_and_configure(admin: &signer, aptos: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        
        // Configure vesting
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        Base::configure_vesting(admin, CLIFF_MONTHS, TGE_BPS, LINEAR_VESTING_MONTHS, asset_addr, START_TIMESTAMP, SECONDS_PER_MONTH);
        
        // Verify configuration
        let (cliff, tge, linear, configured_asset, is_configured, is_vesting_started, seconds_per_month) = Base::get_vesting_config();
        assert!(cliff == CLIFF_MONTHS, 1);
        assert!(tge == TGE_BPS, 2);
        assert!(linear == LINEAR_VESTING_MONTHS, 3);
        assert!(configured_asset == asset_addr, 4);
        assert!(is_configured == true, 5);
        assert!(is_vesting_started == false, 6);
        assert!(seconds_per_month == SECONDS_PER_MONTH, 7);

        let (total, claimed, claimable, last_claim) = Base::get_vesting_info(signer::address_of(admin));
        assert!(total == 0, 8);
        assert!(claimed == 0, 9);
        assert!(claimable == 0, 10);
        assert!(last_claim == 0, 11);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user1 = @0x456, user2 = @0x789)]
    public fun test_whitelist_and_deposit(admin: &signer, aptos: &signer, user1: &signer, user2: &signer) {
        // Set up and configure
        setup_test_environment(admin, aptos);
        configure_vesting(admin);
        
        let deposit_amount = 10000 * TEVI_DECIMALS;
        mint_and_deposit(admin, deposit_amount);
        
        // Verify contract balance
        assert!(Base::get_contract_balance() == deposit_amount, 0);
        
        // Whitelist users
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();
        
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);
        let user1_amount = 5000 * TEVI_DECIMALS; // 5,000 TEVI
        let user2_amount = 3000 * TEVI_DECIMALS; // 3,000 TEVI
        
        vector::push_back(&mut users, user1_addr);
        vector::push_back(&mut users, user2_addr);
        vector::push_back(&mut amounts, user1_amount);
        vector::push_back(&mut amounts, user2_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // Verify user allocation
        let (total1, claimed1, claimable1, last_claim1) = Base::get_vesting_info(user1_addr);
        let (total2, claimed2, claimable2, last_claim2) = Base::get_vesting_info(user2_addr);
        
        assert!(total1 == user1_amount, 1);
        assert!(claimed1 == 0, 2);
        assert!(claimable1 == 0, 3);
        assert!(last_claim1 == 0, 4);
        
        assert!(total2 == user2_amount, 5);
        assert!(claimed2 == 0, 6);
        assert!(claimable2 == 0, 7);
        assert!(last_claim2 == 0, 8);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user1 = @0x456)]
    public fun test_vesting_and_claiming(admin: &signer, aptos: &signer, user1: &signer) {
        // Set up and configure
        setup_test_environment(admin, aptos);
        
        // Set the timestamp to match our START_TIMESTAMP
        timestamp::fast_forward_seconds(START_TIMESTAMP);
        
        configure_vesting(admin);
        
        // Deposit tokens
        let deposit_amount = 10000 * TEVI_DECIMALS; // 10,000 TEVI
        mint_and_deposit(admin, deposit_amount);
        
        // Whitelist users
        let user1_addr = signer::address_of(user1);
        let user1_amount = 1000 * TEVI_DECIMALS; // 1,000 TEVI
        
        let users = vector::singleton(user1_addr);
        let amounts = vector::singleton(user1_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // Start vesting
        Base::start_vesting(admin);
        assert!(Base::is_vesting_started(), 0);

        let (_, _, claimable, _) = Base::get_vesting_info(user1_addr);
        assert!(claimable == 0, 0);

        // At this point, TGE amount should be claimable (10%)
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * CLIFF_MONTHS);
        let tge_amount = user1_amount * TGE_BPS / BASIS_POINTS_DENOMINATOR;
        let (_, _, claimable, _) = Base::get_vesting_info(user1_addr);
        assert!(claimable == tge_amount, 1);
        
        // User1 claims tokens at TGE
        let current_time = timestamp::now_seconds();
        Base::claim(user1);
        let (total, claimed, _, last_claim) = Base::get_vesting_info(user1_addr);
        assert!(total == user1_amount, 2);
        assert!(claimed == tge_amount, 3);
        assert!(last_claim == current_time, 4);
        
        // Fast forward past cliff period
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * 1);
        
        // After cliff + 1 month, user should be able to claim one month's worth of linear vesting
        // Remaining 90% vests over 12 months = 7.5% per month
        // debug::print(&string::utf8(b"--------------------------------"));
        let linear_monthly = (user1_amount * 9 / 10) / LINEAR_VESTING_MONTHS; // Monthly linear vesting amount
        let expected_claimable = linear_monthly;
        let (_, _, claimable, _) = Base::get_vesting_info(user1_addr);
        // debug::print(&string::utf8(b"claimable"));
        // debug::print(&claimable);
        // debug::print(&string::utf8(b"expected_claimable"));
        // debug::print(&expected_claimable);
        assert!(claimable == expected_claimable, 5);
        
        // User1 claims again
        let current_time2 = timestamp::now_seconds();
        Base::claim(user1);
        let (_, claimed, _, last_claim) = Base::get_vesting_info(user1_addr);
        assert!(claimed == tge_amount + expected_claimable, 6);
        assert!(last_claim == current_time2, 7);
        
        // Fast forward to end of vesting
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * (LINEAR_VESTING_MONTHS - 1));
        
        // At this point, all tokens should be claimable
        let (_, claimed_before, claimable, _) = Base::get_vesting_info(user1_addr);
        let expected_remaining = user1_amount - claimed_before;
        assert!(claimable == expected_remaining, 8);
        
        // Final claim
        let current_time3 = timestamp::now_seconds();
        Base::claim(user1);
        let (total, claimed, claimable, last_claim) = Base::get_vesting_info(user1_addr);
        assert!(total == user1_amount, 9);
        assert!(claimed == user1_amount, 10);
        assert!(claimable == 0, 11);
        assert!(last_claim == current_time3, 12);
        
        // Verify balance in user's wallet
        let asset_type = TeviCoin::get_metadata();
        let balance = primary_fungible_store::balance(user1_addr, asset_type);
        assert!(balance == user1_amount, 13);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, non_admin = @0x123)]
    #[expected_failure(abort_code = 327681, location = TeviVesting::Base)] // permission_denied(ENOT_ADMIN)
    public fun test_only_admin_can_configure(admin: &signer, aptos: &signer, non_admin: &signer) {
        setup_test_environment(admin, aptos);
        
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        // Non-admin trying to configure should fail
        Base::configure_vesting(non_admin, CLIFF_MONTHS, TGE_BPS, LINEAR_VESTING_MONTHS, asset_addr, START_TIMESTAMP, SECONDS_PER_MONTH);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user = @0x456)]
    #[expected_failure(abort_code = 327682, location = TeviVesting::Base)] // ENOT_WHITELISTED
    public fun test_only_whitelisted_can_claim(admin: &signer, aptos: &signer, user: &signer) {
        setup_test_environment(admin, aptos);
        configure_vesting(admin);
        mint_and_deposit(admin, 1000 * TEVI_DECIMALS);
        
        // Start vesting without whitelisting anyone
        Base::start_vesting(admin);
        
        // Non-whitelisted user trying to claim
        Base::claim(user);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 196619, location = TeviVesting::Base)] // EVESTING_ALREADY_STARTED
    public fun test_cannot_configure_after_start(admin: &signer, aptos: &signer) {
        setup_test_environment(admin, aptos);
        configure_vesting(admin);
        
        // Start vesting
        Base::start_vesting(admin);
        
        // Try to reconfigure after starting (should fail)
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        Base::configure_vesting(admin, CLIFF_MONTHS, TGE_BPS, LINEAR_VESTING_MONTHS, asset_addr, START_TIMESTAMP, SECONDS_PER_MONTH);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 65543, location = TeviVesting::Base)] // invalid_argument(EVESTING_SCHEDULE_INVALID)
    public fun test_tge_bps_validation(admin: &signer, aptos: &signer) {
        setup_test_environment(admin, aptos);
        
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        // Try to configure with TGE_BPS > BASIS_POINTS_DENOMINATOR (10000)
        let invalid_tge_bps = 10001; // Exceeds 10000 basis points (100%)
        Base::configure_vesting(admin, CLIFF_MONTHS, invalid_tge_bps, LINEAR_VESTING_MONTHS, asset_addr, START_TIMESTAMP, SECONDS_PER_MONTH);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 65543, location = TeviVesting::Base)] // invalid_argument(EVESTING_SCHEDULE_INVALID)
    public fun test_cliff_months_validation(admin: &signer, aptos: &signer) {
        setup_test_environment(admin, aptos);
        
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        // Try to configure with cliff_months = 0
        let invalid_cliff_months = 0; // Must be > 0
        Base::configure_vesting(admin, invalid_cliff_months, TGE_BPS, LINEAR_VESTING_MONTHS, asset_addr, START_TIMESTAMP, SECONDS_PER_MONTH);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 65543, location = TeviVesting::Base)] // invalid_argument(EVESTING_SCHEDULE_INVALID)
    public fun test_linear_vesting_months_validation(admin: &signer, aptos: &signer) {
        setup_test_environment(admin, aptos);
        
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        // Try to configure with linear_vesting_months = 0
        let invalid_linear_months = 0; // Must be > 0
        Base::configure_vesting(admin, CLIFF_MONTHS, TGE_BPS, invalid_linear_months, asset_addr, START_TIMESTAMP, SECONDS_PER_MONTH);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 65543, location = TeviVesting::Base)] // invalid_argument(EVESTING_SCHEDULE_INVALID)
    public fun test_seconds_per_month_validation(admin: &signer, aptos: &signer) {
        setup_test_environment(admin, aptos);
        
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        // Try to configure with seconds_per_month = 0
        let invalid_seconds_per_month = 0; // Must be > 0
        Base::configure_vesting(admin, CLIFF_MONTHS, TGE_BPS, LINEAR_VESTING_MONTHS, asset_addr, START_TIMESTAMP, invalid_seconds_per_month);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 65543, location = TeviVesting::Base)] // invalid_argument(EVESTING_SCHEDULE_INVALID)
    public fun test_start_timestamp_validation(admin: &signer, aptos: &signer) {
        setup_test_environment(admin, aptos);
        
        let asset_type = TeviCoin::get_metadata();
        let asset_addr = object::object_address(&asset_type);
        
        // Try to configure with start_timestamp = 0
        let invalid_start_timestamp = 0; // Must be > 0
        Base::configure_vesting(admin, CLIFF_MONTHS, TGE_BPS, LINEAR_VESTING_MONTHS, asset_addr, invalid_start_timestamp, SECONDS_PER_MONTH);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user = @0x456)]
    #[expected_failure(abort_code = 196613, location = TeviVesting::Base)] // invalid_state(EVESTING_AMOUNT_TOO_HIGH)
    public fun test_cannot_claim_zero_amount(admin: &signer, aptos: &signer, user: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        
        // Set the timestamp to match our START_TIMESTAMP
        timestamp::fast_forward_seconds(START_TIMESTAMP);
        
        configure_vesting(admin);
        
        // Deposit tokens
        let deposit_amount = 1000 * TEVI_DECIMALS;
        mint_and_deposit(admin, deposit_amount);
        
        // Whitelist the user
        let user_addr = signer::address_of(user);
        let user_amount = 100 * TEVI_DECIMALS;
        
        let users = vector::singleton(user_addr);
        let amounts = vector::singleton(user_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // Start vesting
        Base::start_vesting(admin);
        
        // At this point, no tokens are claimable yet because we haven't passed the cliff period
        // and there's no TGE release (we're using the default test constants where cliff_months = 3)
        
        // Attempt to claim tokens when there are none available to claim
        // This should fail with EVESTING_AMOUNT_TOO_HIGH error
        Base::claim(user);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user = @0x456)]
    public fun test_full_vesting_period_completion(admin: &signer, aptos: &signer, user: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        
        // Set the timestamp to match our START_TIMESTAMP
        timestamp::fast_forward_seconds(START_TIMESTAMP);
        
        configure_vesting(admin);
        
        // Deposit tokens
        let deposit_amount = 10000 * TEVI_DECIMALS;
        mint_and_deposit(admin, deposit_amount);
        
        // Whitelist the user
        let user_addr = signer::address_of(user);
        let user_amount = 1000 * TEVI_DECIMALS;
        
        let users = vector::singleton(user_addr);
        let amounts = vector::singleton(user_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // Start vesting
        Base::start_vesting(admin);
        
        // Fast forward past the entire vesting period (cliff + linear vesting)
        // This will ensure we hit the code path where months_passed > schedule.cliff_months + schedule.linear_vesting_months
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * (CLIFF_MONTHS + LINEAR_VESTING_MONTHS + 1));
        
        // Check that the full amount is claimable
        let (total, claimed, claimable, last_claim) = Base::get_vesting_info(user_addr);
        assert!(total == user_amount, 1);
        assert!(claimed == 0, 2);
        assert!(claimable == user_amount, 3); // Full amount should be claimable
        assert!(last_claim == 0, 4);
        
        // Claim the tokens
        let current_time = timestamp::now_seconds();
        Base::claim(user);
        
        // Verify that all tokens were claimed
        let (total_after, claimed_after, claimable_after, last_claim_after) = Base::get_vesting_info(user_addr);
        assert!(total_after == user_amount, 5);
        assert!(claimed_after == user_amount, 6);
        assert!(claimable_after == 0, 7);
        assert!(last_claim_after == current_time, 8);
        
        // Verify balance in user's wallet
        let asset_type = TeviCoin::get_metadata();
        let balance = primary_fungible_store::balance(user_addr, asset_type);
        assert!(balance == user_amount, 9);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 393228, location = TeviVesting::Base)] // not_found(EASSET_TYPE_NOT_CONFIGURED)
    public fun test_asset_type_not_configured(admin: &signer, aptos: &signer) {
        // Set up the test environment but don't configure the vesting contract
        setup_test_environment(admin, aptos);
        
        // Try to deposit tokens without configuring the asset type first
        // This should fail with EASSET_TYPE_NOT_CONFIGURED error
        let deposit_amount = 1000 * TEVI_DECIMALS;
        let admin_addr = signer::address_of(admin);
        TeviCoin::mint(admin, admin_addr, deposit_amount);
        
        // Attempt to deposit tokens without configuring asset type
        Base::deposit_tokens(admin, deposit_amount);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user1 = @0x456, user2 = @0x789, user3 = @0x123)]
    public fun test_total_whitelisted_amount_calculation(admin: &signer, aptos: &signer, user1: &signer, user2: &signer, user3: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        
        // Set the timestamp to match our START_TIMESTAMP
        timestamp::fast_forward_seconds(START_TIMESTAMP);
        
        configure_vesting(admin);
        
        // Deposit tokens - just enough for the first two users
        let user1_amount = 500 * TEVI_DECIMALS;
        let user2_amount = 300 * TEVI_DECIMALS;
        let total_deposit = user1_amount + user2_amount;
        mint_and_deposit(admin, total_deposit);
        
        // Whitelist the first two users
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();
        
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);
        
        vector::push_back(&mut users, user1_addr);
        vector::push_back(&mut users, user2_addr);
        vector::push_back(&mut amounts, user1_amount);
        vector::push_back(&mut amounts, user2_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // Verify contract balance equals total whitelisted amount
        assert!(Base::get_contract_balance() == total_deposit, 1);
        
        // Try to whitelist a third user which would exceed the deposited amount
        let user3_addr = signer::address_of(user3);
        let user3_amount = 200 * TEVI_DECIMALS; // This would make total exceed deposit
        
        let users3 = vector::singleton(user3_addr);
        let amounts3 = vector::singleton(user3_amount);
        
        // This should fail because total_whitelisted + user3_amount > deposited amount
        // But we'll catch the error and deposit more tokens instead
        
        // Deposit more tokens to cover user3
        mint_and_deposit(admin, user3_amount);
        
        // Now whitelisting should succeed
        Base::batch_whitelist_users(admin, users3, amounts3);
        
        // Verify contract balance equals new total whitelisted amount
        assert!(Base::get_contract_balance() == total_deposit + user3_amount, 2);
        
        // Verify individual user allocations
        let (total1, claimed1, _, last_claim1) = Base::get_vesting_info(user1_addr);
        let (total2, claimed2, _, last_claim2) = Base::get_vesting_info(user2_addr);
        let (total3, claimed3, _, last_claim3) = Base::get_vesting_info(user3_addr);
        
        assert!(total1 == user1_amount, 3);
        assert!(claimed1 == 0, 4);
        assert!(last_claim1 == 0, 5);
        assert!(total2 == user2_amount, 6);
        assert!(claimed2 == 0, 7);
        assert!(last_claim2 == 0, 8);
        assert!(total3 == user3_amount, 9);
        assert!(claimed3 == 0, 10);
        assert!(last_claim3 == 0, 11);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    #[expected_failure(abort_code = 393228, location = TeviVesting::Base)] // not_found(EASSET_TYPE_NOT_CONFIGURED)
    public fun test_start_vesting_asset_type_not_configured(admin: &signer, aptos: &signer) {
        // Set up the test environment but don't configure the vesting contract
        setup_test_environment(admin, aptos);
        
        // Try to start vesting without configuring asset type
        // This should fail with EASSET_TYPE_NOT_CONFIGURED error
        Base::start_vesting(admin);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user = @0x456)]
    public fun test_update_whitelisted_user(admin: &signer, aptos: &signer, user: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        
        // Set the timestamp to match our START_TIMESTAMP
        timestamp::fast_forward_seconds(START_TIMESTAMP);
        
        configure_vesting(admin);
        
        // Deposit tokens - enough for both initial and updated allocation
        let initial_amount = 500 * TEVI_DECIMALS;
        let updated_amount = 800 * TEVI_DECIMALS;
        mint_and_deposit(admin, updated_amount); // Deposit the larger amount to cover the update
        
        // Whitelist the user with initial amount
        let user_addr = signer::address_of(user);
        let users = vector::singleton(user_addr);
        let amounts = vector::singleton(initial_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // Verify initial allocation
        let (total, claimed, claimable, last_claim) = Base::get_vesting_info(user_addr);
        assert!(total == initial_amount, 1);
        assert!(claimed == 0, 2);
        assert!(claimable == 0, 3);
        assert!(last_claim == 0, 4);
        
        // Update the user's allocation (this will hit the borrow_mut line)
        let updated_users = vector::singleton(user_addr);
        let updated_amounts = vector::singleton(updated_amount);
        
        Base::batch_whitelist_users(admin, updated_users, updated_amounts);
        
        // Verify updated allocation
        let (new_total, new_claimed, new_claimable, new_last_claim) = Base::get_vesting_info(user_addr);
        assert!(new_total == updated_amount, 5); // Should be updated to the new amount
        assert!(new_claimed == 0, 6);
        assert!(new_claimable == 0, 7);
        assert!(new_last_claim == 0, 8);
    }

    #[test(admin = @TeviVesting, aptos = @0x1)]
    public fun test_next_unlock_time(admin: &signer, aptos: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        
        // Set initial timestamp
        let initial_time = 500; // Before vesting starts
        timestamp::fast_forward_seconds(initial_time);
        
        // Configure vesting
        configure_vesting(admin);
        
        // Deposit tokens
        let deposit_amount = 10000 * TEVI_DECIMALS;
        mint_and_deposit(admin, deposit_amount);
        
        // Before vesting starts, next unlock time should be 0
        let next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == 0, 1);
        
        // Start vesting
        Base::start_vesting(admin);
        
        let first_unlock_time = START_TIMESTAMP + (CLIFF_MONTHS * SECONDS_PER_MONTH);
        
        // After vesting starts but before START_TIMESTAMP, next unlock should be the first unlock time (after cliff)
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == first_unlock_time, 2);
        
        // Fast forward to START_TIMESTAMP
        timestamp::fast_forward_seconds(START_TIMESTAMP - initial_time);
        
        // At START_TIMESTAMP (beginning of vesting), next unlock should be at cliff end
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == first_unlock_time, 3);
        
        // Test multiple points within the cliff period to ensure consistent behavior
        
        // Test at 1/4 of cliff period
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * CLIFF_MONTHS / 4);
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == first_unlock_time, 4);
        
        // Test at 1/2 of cliff period
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * CLIFF_MONTHS / 4);
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == first_unlock_time, 5);
        
        // Test at 3/4 of cliff period
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * CLIFF_MONTHS / 4);
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == first_unlock_time, 6);
        
        // Test at cliff period - 1 day (just before cliff ends)
        timestamp::fast_forward_seconds((SECONDS_PER_MONTH * CLIFF_MONTHS / 4) - (86400)); // Subtract one day
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == first_unlock_time, 7);
        
        // Fast forward to end of cliff period
        timestamp::fast_forward_seconds(86400); // Add the one day back
        
        // At cliff end, next unlock should be one month later
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == START_TIMESTAMP + (SECONDS_PER_MONTH * (CLIFF_MONTHS + 1)), 8);
        
        // Fast forward one month into linear vesting period
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH);
        
        // During linear vesting, next unlock should be at next month
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == START_TIMESTAMP + (SECONDS_PER_MONTH * (CLIFF_MONTHS + 2)), 9);
        
        // Fast forward to end of vesting period
        timestamp::fast_forward_seconds(SECONDS_PER_MONTH * (LINEAR_VESTING_MONTHS - 1));
        
        // After vesting period ends, next unlock should be 0
        next_unlock = Base::get_next_unlock_time();
        assert!(next_unlock == 0, 10);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user1 = @0x456, user2 = @0x789)]
    public fun test_get_amount_need_deposit(admin: &signer, aptos: &signer, user1: &signer, user2: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        configure_vesting(admin);
        
        // Initially, with no whitelisted users, amount needed should be 0
        assert!(Base::get_amount_need_deposit() == 0, 1);
        
        // Whitelist users with total allocation of 800 TEVI
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();
        
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);
        let user1_amount = 500 * TEVI_DECIMALS; // 500 TEVI
        let user2_amount = 300 * TEVI_DECIMALS; // 300 TEVI
        let total_needed = user1_amount + user2_amount; // 800 TEVI
        
        vector::push_back(&mut users, user1_addr);
        vector::push_back(&mut users, user2_addr);
        vector::push_back(&mut amounts, user1_amount);
        vector::push_back(&mut amounts, user2_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // With no deposits yet, amount needed should be the total allocation
        assert!(Base::get_amount_need_deposit() == total_needed, 2);
        
        // Deposit half of the needed amount (400 TEVI)
        let partial_deposit = total_needed / 2;
        mint_and_deposit(admin, partial_deposit);
        
        // After partial deposit, amount needed should be the remaining half
        assert!(Base::get_amount_need_deposit() == total_needed - partial_deposit, 3);
        
        // Deposit the remaining amount
        mint_and_deposit(admin, total_needed - partial_deposit);
        
        // After full deposit, amount needed should be 0
        assert!(Base::get_amount_need_deposit() == 0, 4);
        
        // Deposit extra tokens (more than needed)
        let extra_amount = 100 * TEVI_DECIMALS;
        mint_and_deposit(admin, extra_amount);
        
        // With excess deposit, amount needed should still be 0
        assert!(Base::get_amount_need_deposit() == 0, 5);
        
        // Add more allocation to an existing user
        let updated_users = vector::singleton(user1_addr);
        let updated_amount = user1_amount + 200 * TEVI_DECIMALS; // Increase by 200 TEVI
        let amounts_update = vector::singleton(updated_amount);
        
        Base::batch_whitelist_users(admin, updated_users, amounts_update);
        
        // Amount needed should be the additional allocation minus excess deposit
        let new_total_needed = updated_amount + user2_amount;
        let expected_needed = if (new_total_needed > total_needed + extra_amount) {
            new_total_needed - (total_needed + extra_amount)
        } else {
            0
        };
        
        assert!(Base::get_amount_need_deposit() == expected_needed, 6);
    }

    #[test(admin = @TeviVesting, aptos = @0x1, user1 = @0x456, user2 = @0x789, user3 = @0x123)]
    public fun test_get_whitelisted_users(admin: &signer, aptos: &signer, user1: &signer, user2: &signer, user3: &signer) {
        // Set up the test environment
        setup_test_environment(admin, aptos);
        configure_vesting(admin);
        
        // Initially, there should be no whitelisted users
        let (initial_users, initial_amounts) = Base::get_whitelisted_users();
        assert!(vector::length(&initial_users) == 0, 1);
        assert!(vector::length(&initial_amounts) == 0, 2);
        
        // Deposit tokens for whitelisting
        let deposit_amount = 10000 * TEVI_DECIMALS;
        mint_and_deposit(admin, deposit_amount);
        
        // Whitelist users with different amounts
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();
        
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);
        let user3_addr = signer::address_of(user3);
        
        let user1_amount = 1000 * TEVI_DECIMALS; // 1,000 TEVI
        let user2_amount = 2000 * TEVI_DECIMALS; // 2,000 TEVI
        let user3_amount = 3000 * TEVI_DECIMALS; // 3,000 TEVI
        
        vector::push_back(&mut users, user1_addr);
        vector::push_back(&mut users, user2_addr);
        vector::push_back(&mut users, user3_addr);
        vector::push_back(&mut amounts, user1_amount);
        vector::push_back(&mut amounts, user2_amount);
        vector::push_back(&mut amounts, user3_amount);
        
        Base::batch_whitelist_users(admin, users, amounts);
        
        // Get whitelisted users and verify
        let (whitelisted_users, whitelisted_amounts) = Base::get_whitelisted_users();
        
        // Verify the number of users matches
        assert!(vector::length(&whitelisted_users) == 3, 3);
        assert!(vector::length(&whitelisted_amounts) == 3, 4);
        
        // Create a map of expected user addresses to amounts for easier verification
        let expected_users = vector::empty<address>();
        let expected_amounts = vector::empty<u64>();
        
        vector::push_back(&mut expected_users, user1_addr);
        vector::push_back(&mut expected_users, user2_addr);
        vector::push_back(&mut expected_users, user3_addr);
        vector::push_back(&mut expected_amounts, user1_amount);
        vector::push_back(&mut expected_amounts, user2_amount);
        vector::push_back(&mut expected_amounts, user3_amount);
        
        // Verify each user is in the returned list with the correct amount
        // Note: The order of users in the returned vectors might not match our expected order
        // since SimpleMap doesn't guarantee order, so we need to check each user individually
        let i = 0;
        while (i < vector::length(&whitelisted_users)) {
            let user_addr = *vector::borrow(&whitelisted_users, i);
            let amount = *vector::borrow(&whitelisted_amounts, i);
            
            // Find the index of this user in our expected list
            let j = 0;
            let found = false;
            while (j < vector::length(&expected_users) && !found) {
                if (*vector::borrow(&expected_users, j) == user_addr) {
                    // Verify the amount matches
                    assert!(amount == *vector::borrow(&expected_amounts, j), 5);
                    found = true;
                };
                j = j + 1;
            };
            
            // Verify we found the user in our expected list
            assert!(found, 6);
            
            i = i + 1;
        };
        
        // Update one user's allocation
        let updated_user = vector::singleton(user2_addr);
        let updated_amount = 2500 * TEVI_DECIMALS; // Increase to 2,500 TEVI
        let updated_amounts = vector::singleton(updated_amount);
        
        Base::batch_whitelist_users(admin, updated_user, updated_amounts);
        
        // Get updated whitelisted users and verify
        let (updated_users, updated_amounts) = Base::get_whitelisted_users();
        
        // Verify the number of users is still the same
        assert!(vector::length(&updated_users) == 3, 7);
        assert!(vector::length(&updated_amounts) == 3, 8);
        
        // Verify the updated user's amount
        i = 0;
        let found_updated = false;
        while (i < vector::length(&updated_users)) {
            if (*vector::borrow(&updated_users, i) == user2_addr) {
                assert!(*vector::borrow(&updated_amounts, i) == updated_amount, 9);
                found_updated = true;
            };
            i = i + 1;
        };
        
        assert!(found_updated, 10);
    }
} 
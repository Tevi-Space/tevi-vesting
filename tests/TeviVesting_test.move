#[test_only]
module TeviVesting::BaseTests {
    use std::signer;
    use std::vector;
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::fungible_asset::{MintRef, BurnRef};
    use TeviCoin::TeviCoin;
    use TeviVesting::Base;

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
            account::create_account_for_test(signer::address_of(admin));
        };
        if (!account::exists_at(signer::address_of(user))) {
            account::create_account_for_test(signer::address_of(user));
        };
        if (!account::exists_at(Base::get_vesting_address())) {
            account::create_account_for_test(Base::get_vesting_address());
        };

        // Initialize TeviCoin first
        TeviCoin::initialize_for_test(admin);

        // Initialize vesting contract
        Base::initialize(admin, TEST_CLIFF_MONTHS, TEST_TGE_BPS, TEST_LINEAR_MONTHS);

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
    ) {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT);

        // Check contract balance
        let vesting_balance = Base::get_contract_balance();
        assert!(vesting_balance == TEST_AMOUNT, 1);

        // Whitelist user
        let user_amount = TEST_AMOUNT / 2;
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(user_amount);
        Base::batch_whitelist_users(admin, users, amounts);

        // Check whitelist info
        let (total, claimed, _) = Base::get_vesting_info(signer::address_of(user));
        assert!(total == user_amount, 2);
        assert!(claimed == 0, 3);

        // Start vesting
        Base::start_vesting(admin);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test initialization with valid parameters
    fun test_initialize_valid(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        // Initialize all accounts first
        timestamp::set_time_has_started_for_testing(aptos);

        // Create accounts if they don't exist
        if (!account::exists_at(signer::address_of(admin))) {
            account::create_account_for_test(signer::address_of(admin));
        };
        if (!account::exists_at(signer::address_of(user))) {
            account::create_account_for_test(signer::address_of(user));
        };
        
        // Create vesting contract account
        let vesting_addr = Base::get_vesting_address();
        if (!account::exists_at(vesting_addr)) {
            account::create_account_for_test(vesting_addr);
        };

        // Initialize TeviCoin first
        TeviCoin::initialize_for_test(admin);

        // Initialize vesting contract
        Base::initialize(admin, TEST_CLIFF_MONTHS, TEST_TGE_BPS, TEST_LINEAR_MONTHS);

        // Verify contract state
        assert!(Base::get_schedule_cliff_months() == TEST_CLIFF_MONTHS, 1);
        assert!(Base::get_schedule_tge_bps() == TEST_TGE_BPS, 2);
        assert!(Base::get_schedule_linear_vesting_months() == TEST_LINEAR_MONTHS, 3);
        assert!(Base::get_contract_balance() == 0, 4);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test claiming after TGE
    fun test_claim_after_tge(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        Base::batch_whitelist_users(admin, users, amounts);

        // Start vesting
        Base::start_vesting(admin);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // Claim tokens
        Base::claim(user);

        // Check claimed amount (should be TGE amount)
        let (_, claimed, _) = Base::get_vesting_info(signer::address_of(user));
        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (10000 as u128);
        assert!(claimed == (expected_tge as u64), 1);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test claiming after full vesting period
    fun test_claim_after_full_vesting(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        Base::batch_whitelist_users(admin, users, amounts);

        // Start vesting
        Base::start_vesting(admin);

        // Move time to after full vesting period
        timestamp::fast_forward_seconds((TEST_CLIFF_MONTHS + TEST_LINEAR_MONTHS) * MONTH_IN_SECONDS);

        // Claim tokens
        Base::claim(user);

        // Check claimed amount (should be full amount)
        let (total, claimed, _) = Base::get_vesting_info(signer::address_of(user));
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
    ) {
        setup_test(aptos, admin, user);

        // Mint tokens to user (so they have something to deposit)
        TeviCoin::mint(admin, signer::address_of(user), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Try unauthorized deposit (should fail)
        Base::deposit_tokens(user, TEST_AMOUNT);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 327682, location=TeviVesting::Base)]
    /// Test claim by non-whitelisted user
    fun test_claim_not_whitelisted(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        setup_test(aptos, admin, user);
        Base::claim(user); // Should fail as user is not whitelisted
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 196613, location=TeviVesting::Base)]
    /// Test claim before cliff period
    fun test_claim_before_cliff(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Mint and deposit tokens
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);
        Base::deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        Base::batch_whitelist_users(admin, users, amounts);

        // Start vesting
        Base::start_vesting(admin);

        // Try to claim before cliff period
        Base::claim(user); // Should fail
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    /// Test multiple claims during linear vesting period
    fun test_multiple_claims_during_vesting(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        Base::batch_whitelist_users(admin, users, amounts);

        // Start vesting
        Base::start_vesting(admin);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // First claim (TGE amount)
        Base::claim(user);
        let (_, claimed_after_tge, _) = Base::get_vesting_info(signer::address_of(user));
        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (10000 as u128);
        assert!(claimed_after_tge == (expected_tge as u64), 1);

        // Move time 6 months into linear vesting
        timestamp::fast_forward_seconds(6 * MONTH_IN_SECONDS);

        // Second claim
        Base::claim(user);
        let (_, claimed_after_6_months, _) = Base::get_vesting_info(signer::address_of(user));
        assert!(claimed_after_6_months > claimed_after_tge, 2);

        // Move time to end of vesting
        timestamp::fast_forward_seconds(30 * MONTH_IN_SECONDS);

        // Final claim
        Base::claim(user);
        let (total, claimed_final, _) = Base::get_vesting_info(signer::address_of(user));
        assert!(claimed_final == total, 3);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123, user2 = @0x456)]
    /// Test multiple users vesting
    fun test_multiple_users_vesting(
        aptos: &signer,
        admin: &signer,
        user: &signer,
        user2: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Create account for user2
        if (!account::exists_at(signer::address_of(user2))) {
            account::create_account_for_test(signer::address_of(user2));
        };

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT * 2);

        // Create primary store for users
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user2), metadata);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT * 2);

        // Whitelist users with different amounts
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();
        
        vector::push_back(&mut users, signer::address_of(user));
        vector::push_back(&mut users, signer::address_of(user2));
        
        vector::push_back(&mut amounts, TEST_AMOUNT);
        vector::push_back(&mut amounts, TEST_AMOUNT);
        
        Base::batch_whitelist_users(admin, users, amounts);

        // Start vesting
        Base::start_vesting(admin);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // Both users claim
        Base::claim(user);
        Base::claim(user2);

        // Verify both users received TGE amount
        let (_, claimed1, _) = Base::get_vesting_info(signer::address_of(user));
        let (_, claimed2, _) = Base::get_vesting_info(signer::address_of(user2));
        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (10000 as u128);
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
    ) {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Create primary store for user
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT);

        // Whitelist user
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        Base::batch_whitelist_users(admin, users, amounts);

        // Start vesting
        Base::start_vesting(admin);

        // Move time to after cliff period
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        // First claim
        Base::claim(user);

        // Try to claim again immediately (should fail as no new tokens are vested)
        Base::claim(user);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 196617, location=TeviVesting::Base)]
    /// Test insufficient balance for whitelist
    fun test_insufficient_balance_whitelist(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Mint and deposit small amount
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT / 2);
        Base::deposit_tokens(admin, TEST_AMOUNT / 2);

        // Try to whitelist more than available balance
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        Base::batch_whitelist_users(admin, users, amounts);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123)]
    #[expected_failure(abort_code = 196618, location=TeviVesting::Base)]
    /// Test whitelisting after vesting has started
    fun test_whitelist_after_vesting_started(
        aptos: &signer,
        admin: &signer,
        user: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT);

        // Start vesting
        Base::start_vesting(admin);

        // Attempt to whitelist after vesting has started (should fail)
        let users = vector::singleton(signer::address_of(user));
        let amounts = vector::singleton(TEST_AMOUNT);
        Base::batch_whitelist_users(admin, users, amounts);
    }

    #[test(aptos = @0x1, admin = @TeviVesting, user = @0x123, user2 = @0x456, user3 = @0x789)]
    /// Test batch whitelist functionality
    fun test_batch_whitelist(
        aptos: &signer,
        admin: &signer,
        user: &signer,
        user2: &signer,
        user3: &signer,
    ) {
        setup_test(aptos, admin, user);

        // Create accounts for additional users
        if (!account::exists_at(signer::address_of(user2))) {
            account::create_account_for_test(signer::address_of(user2));
        };
        if (!account::exists_at(signer::address_of(user3))) {
            account::create_account_for_test(signer::address_of(user3));
        };

        // Mint tokens to admin
        TeviCoin::mint(admin, signer::address_of(admin), TEST_AMOUNT * 3);

        // Create primary store for users
        let metadata = TeviCoin::get_metadata();
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user), metadata);
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user2), metadata);
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(user3), metadata);

        // Deposit tokens
        Base::deposit_tokens(admin, TEST_AMOUNT * 3);

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
        Base::batch_whitelist_users(admin, users, amounts);

        // Start vesting
        Base::start_vesting(admin);

        // Verify all users are whitelisted with correct amounts
        let (total1, claimed1, _) = Base::get_vesting_info(signer::address_of(user));
        let (total2, claimed2, _) = Base::get_vesting_info(signer::address_of(user2));
        let (total3, claimed3, _) = Base::get_vesting_info(signer::address_of(user3));

        assert!(total1 == TEST_AMOUNT, 1);
        assert!(total2 == TEST_AMOUNT, 2);
        assert!(total3 == TEST_AMOUNT, 3);
        assert!(claimed1 == 0, 4);
        assert!(claimed2 == 0, 5);
        assert!(claimed3 == 0, 6);

        // Move time to after cliff period and verify all users can claim
        timestamp::fast_forward_seconds(TEST_CLIFF_MONTHS * MONTH_IN_SECONDS);

        Base::claim(user);
        Base::claim(user2);
        Base::claim(user3);

        let expected_tge = (TEST_AMOUNT as u128) * (TEST_TGE_BPS as u128) / (10000 as u128);
        let (_, claimed1_after, _) = Base::get_vesting_info(signer::address_of(user));
        let (_, claimed2_after, _) = Base::get_vesting_info(signer::address_of(user2));
        let (_, claimed3_after, _) = Base::get_vesting_info(signer::address_of(user3));

        assert!(claimed1_after == (expected_tge as u64), 7);
        assert!(claimed2_after == (expected_tge as u64), 8);
        assert!(claimed3_after == (expected_tge as u64), 9);
    }
} 
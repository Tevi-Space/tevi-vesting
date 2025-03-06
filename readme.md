## Tevi Vesting SMC - Aptos Cli Version `6.1.1`
```
aptos init --network testnet --profile tevi-developer
```

## Build & Deploy - Dev
1. Compile `TeviCoin` First
```
aptos move compile --named-addresses TeviCoin=0x1
```

2. Compile `TeviVesting`
```
aptos move compile --named-addresses TeviCoin=0x1,TeviVesting=0x1
```

3. Test `TeviVesting`
```
aptos move test --named-addresses TeviCoin=0x1,TeviVesting=0x1
```

## Build & Deploy - Main
1. Compile `TeviCoin` First
```
aptos move compile --named-addresses TeviCoin=tevi-developer
```

2. Compile `TeviVesting`
```
aptos move compile --named-addresses TeviCoin=tevi-developer,TeviVesting=tevi-developer
```

3. Test `TeviVesting`
```
aptos move test --named-addresses TeviCoin=tevi-developer,TeviVesting=tevi-developer
```

4. Deploy `TeviVesting`
```
aptos move publish --named-addresses TeviCoin=tevi-developer,TeviVesting=tevi-developer --profile tevi-developer
```

## Initialize Vesting Contracts
After deployment, each vesting contract needs to be initialized with its specific parameters:

1. Private Investor Vesting (3 months cliff, 10% TGE, 36 months linear)
```
aptos move run --function-id 'tevi-developer::PrivateInvestor::initialize' --profile tevi-developer
```

2. Seed and Angle Vesting (6 months cliff, 10% TGE, 36 months linear)
```
aptos move run --function-id 'tevi-developer::SeedAndAngle::initialize' --profile tevi-developer
```

3. Team and Advisor Vesting (6 months cliff, 0% TGE, 60 months linear)
```
aptos move run --function-id 'tevi-developer::TeamAndAdvisor::initialize' --profile tevi-developer
```

4. Foundation Vesting (3 months cliff, 0% TGE, 60 months linear)
```
aptos move run --function-id 'tevi-developer::Foundation::initialize' --profile tevi-developer
```

5. Ecosystem Vesting (3 months cliff, 0% TGE, 60 months linear)
```
aptos move run --function-id 'tevi-developer::Ecosystem::initialize' --profile tevi-developer
```

## Contract Interaction Commands

### Admin Functions

1. Deposit Tokens to Contract
```
aptos move run --function-id 'tevi-developer::Base::deposit_tokens' \
  --args 'u64:1000000' \
  --profile tevi-developer
```

2. Whitelist User
```
aptos move run --function-id 'tevi-developer::Base::whitelist_user' \
  --args 'address:0x123...456' 'u64:1000000' \
  --profile tevi-developer
```

### User Functions

1. Claim Vested Tokens
```
aptos move run --function-id 'tevi-developer::Base::claim' \
  --profile user-profile
```

### View Functions

1. Get User Vesting Info
```
aptos move view --function-id 'tevi-developer::Base::get_vesting_info' \
  --args 'address:0x123...456'
```

2. Get Contract Balance
```
aptos move view --function-id 'tevi-developer::Base::get_contract_balance'
```

3. Get Vesting Schedule
```
aptos move view --function-id 'tevi-developer::Base::get_vesting_schedule'
```

### Flow:
Luồng hoạt động sẽ như sau:
1. Admin khởi tạo contract với các tham số vesting (cliff, TGE, linear vesting)
2. Admin nạp TeviCoin vào contract bằng hàm deposit_tokens
3. Admin thêm users vào whitelist với số lượng token được phép vesting
4. Users có thể claim token đã được unlock bằng hàm claim
5. Token sẽ được chuyển trực tiếp từ contract về ví của user

### Important Notes:
1. Make sure you have the `tevi-developer` profile configured in your Aptos CLI
2. Replace `tevi-developer` with your actual account address if different
3. All contracts are deployed under the same address specified in `TeviVesting`
4. Each initialization command must be run with the admin account
5. TeviCoin must be deployed and accessible before deploying these contracts
6. Follow the deployment sequence:
   - Deploy TeviCoin first
   - Deploy TeviVesting contracts
   - Initialize each vesting contract
   - Deposit tokens to the contracts
   - Whitelist users
   - Users can then claim their tokens according to the vesting schedule

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
aptos move compile --named-addresses TeviCoin=tevi-developer,TeviVesting=tevi-developer,TeviWallet=tevi-developer
```

3. Test `TeviVesting`
```
aptos move test --named-addresses TeviCoin=tevi-developer,TeviVesting=tevi-developer,TeviWallet=tevi-developer --coverage
```

4. Deploy `TeviVesting`
```
aptos move publish --named-addresses TeviVesting=tevi-developer --profile tevi-developer
```

## Initialize Vesting Contracts
Eg: Ecosystem Vesting (3 months cliff, 0% TGE, 60 months linear)
```
aptos move run --function-id 'tevi-developer::Base::configure_vesting' \
  --args 'u64:3' 'u64:0' 'u64:60' 'address:${TEVI_COIN_ADDRESS}' 'u64:2592000' \
  --profile tevi-developer
```
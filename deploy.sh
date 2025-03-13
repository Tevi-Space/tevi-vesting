#!/bin/bash

# Get TeviCoin metadata address
TEVI_COIN_ADDRESS="0x4a60d406b7e5c786ee91a52fe6d1f5cd0a034301f5d80b5c6f83dc2e748f9a28"
PROFILE_DEPLOY="tevi-vesting-3"

echo "Initializing profile $PROFILE_DEPLOY"
aptos init --network testnet --profile $PROFILE_DEPLOY

echo "Deploying TeviVesting"

# Create a temporary file for the whitelist script
cat > sources/whitelist_users.move << 'EOF'
module TeviVesting::Whitelist {
    use std::vector;
    use TeviVesting::Base;

    public entry fun whitelist_users(admin: &signer) {
        let users = vector::empty<address>();
        let amounts = vector::empty<u64>();

        vector::push_back(&mut users, @0x2259ffb96f1ca6cd43fa6aa5166f4094c60ca4e7d34fca596598db87c64b72b7);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x3a4216d8d83524a83a69ead4ccc498b3b57af72ced5c77e4443df42eab0ebb9c);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x06505a7bb46e2380297afacda55c77cd676aed0254226483a98acc931f3360e0);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x33c5d84f800f2375d3d9e0aff4dc6ee37b634834ffef1a1bb134fe0b35801bb0);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x49df462a940c73435075ad9658bd33f43adfe0ad720562a3520506661a8ee119);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x5c76aff3006524fd06ae44885e5e05ff915eb15c80c23161ff4089faf3077ab9);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0xe0cea714889388894a1aa0b80968003663aafc794ea8ae52872c64df392fa1d5);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x5237a158f4ed8ac2c5d1a2ca031fbde6adc2acc06622c0a90c74fc3a2a71b872);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x5eca6e89e2ef95045e4d7605f9624c867ed3f8833a25c8c885537151d11f1428);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0xa908741de303323e7b5045eef735aa674227c7b3c58a1b03fbc73480737b31ca);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0xaadcde91268ea971231c1f45307f0e26f350b6b52cb797ef0badf821622f564c);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x1e31420ccdee9253ee1c733e6a4f18dd5c5a9fb2ee67f4f31c5c0e6c264e96df);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x036fa2b550b150065e4b944b209e66e43b9d6e78732f5028b72355b20efe1df2);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0x40fef6bc80655822040d7abff3f83297c8ec82ea5385264e8b23008c3d4637e6);
        vector::push_back(&mut amounts, 100000000000);

        vector::push_back(&mut users, @0xb6bc5f361147630920ba848aefa3b5a99b7d0b5762d933b5dfab84ef6d77ede0);
        vector::push_back(&mut amounts, 100000000000);

        Base::batch_whitelist_users(admin, users, amounts);
    }
}
EOF

# Compile and publish the whitelist module
# aptos move compile --named-addresses TeviVesting=$PROFILE_DEPLOY --save-metadata
aptos move publish --named-addresses TeviVesting=$PROFILE_DEPLOY --profile $PROFILE_DEPLOY

# # Private Investor Vesting (3 months cliff, 10% TGE, 36 months linear)
aptos move run --function-id "${PROFILE_DEPLOY}::Base::configure_vesting" \
--args "u64:3" "u64:1000" "u64:36" "address:$TEVI_COIN_ADDRESS" "u64:1741856400" "u64:300" \
--profile $PROFILE_DEPLOY

# Run the whitelist function
aptos move run --function-id "${PROFILE_DEPLOY}::Whitelist::whitelist_users" --profile $PROFILE_DEPLOY

# Deposit tokens
aptos move run --function-id "${PROFILE_DEPLOY}::Base::deposit_tokens" \
--args "u64:1500000000000" \
--profile $PROFILE_DEPLOY

# Start vesting
aptos move run --function-id "${PROFILE_DEPLOY}::Base::start_vesting" \
--profile $PROFILE_DEPLOY

# # Seed and Angle Vesting (6 months cliff, 10% TGE, 36 months linear)
# aptos move run --function-id 'tevi-developer::Base::configure_vesting' \
# --args "u64:6" "u64:1000" "u64:36" "address:$TEVI_COIN_ADDRESS" "u64:2592000" \
# --profile tevi-developer

# # Team and Advisor Vesting (6 months cliff, 0% TGE, 60 months linear)
# aptos move run --function-id 'tevi-developer::Base::configure_vesting' \
# --args "u64:6" "u64:0" "u64:60" "address:$TEVI_COIN_ADDRESS" "u64:2592000" \
# --profile tevi-developer

# # Foundation Vesting (3 months cliff, 0% TGE, 60 months linear)
# aptos move run --function-id 'tevi-developer::Base::configure_vesting' \
# --args "u64:3" "u64:0" "u64:60" "address:$TEVI_COIN_ADDRESS" "u64:2592000" \
# --profile tevi-developer

# # Ecosystem Vesting (3 months cliff, 0% TGE, 60 months linear)
# aptos move run --function-id 'tevi-developer::Base::configure_vesting' \
# --args "u64:3" "u64:0" "u64:60" "address:$TEVI_COIN_ADDRESS" "u64:2592000" \
# --profile tevi-developer
include .env

export $(shell sed 's/=.*//' .env)

remove:
	rm -rf .gitmodules && rm -rf .git/modules && rm -rf lib && touch .gitmodules 

install:
	forge install foundry-rs/forge-std --no-commit && forge install uniswap/v4-periphery --no-commit

build:
	forge build

clean:
	forge clean

update:
	forge update

test:
	forge test

mine-superhook-addr:
	forge script script/MineAddress.s.sol:SuperHookAddressMiner

mine-oracle-addr:
	forge script script/demo/MineOracleAddress.s.sol:GeomeanOracleSubHookAddressMiner --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

mine-points-addr:
	forge script script/demo/MinePointsAddress.s.sol:PointsHookSubHookAddressMiner --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

test-deploy-tokens:
	forge script script/01_DeployTokens.s.sol:DeployTokens --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

deploy-tokens:
	forge script script/01_DeployTokens.s.sol:DeployTokens --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

test-deploy-superhook:
	forge script script/02_DeploySuperHook.s.sol:SuperHookDeployer --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

deploy-superhook:
	forge script script/02_DeploySuperHook.s.sol:SuperHookDeployer --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

test-create-pool:
	forge script script/03_CreatePool.s.sol:CreatePool --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

create-pool:
	forge script script/03_CreatePool.s.sol:CreatePool --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

test-deploy-subhooks:
	forge script script/04_DeploySubHooks.s.sol:DeploySubHooks --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

deploy-subhooks:
	forge script script/04_DeploySubHooks.s.sol:DeploySubHooks --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast

test-demo:
	@forge script script/05_DemoSwaps.s.sol:DemoSwaps --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY)

demo:
	@forge script script/05_DemoSwaps.s.sol:DemoSwaps --rpc-url $(RPC_URL) --sender $(SENDER) --etherscan-api-key $(API_KEY) --verify --broadcast
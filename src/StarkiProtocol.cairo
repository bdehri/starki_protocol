use starknet::ContractAddress;


// External Interfaces
#[starknet::interface]
trait IERC20<T> {
    fn transfer_from(ref self: T, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool;
    fn transferFrom(ref self: T, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool; // TODO Remove after regenesis
    fn transfer(ref self: T,recipient: ContractAddress, amount: u128) -> bool;
    fn approve(ref self: T, spender: ContractAddress, amount: u256) -> bool;
    fn balance_of(self: @T, account: ContractAddress) -> u256;
}

#[starknet::interface]
trait Router<K> {
    fn addLiquidity(ref self: K, token_a: ContractAddress, token_b: ContractAddress, stable: felt252, amount_a_desired: u256, 
        amount_b_desired: u256, amount_a_min: u256, amount_b_min: u256, to: ContractAddress, deadline: u64) -> (u256, u256,u256);
    fn quoteAddLiquidity(self: @K, token_a: ContractAddress, token_b: ContractAddress, stable: felt252, amount_a_desired: u256, amount_b_desired: u256) -> (u256,u256,u256);
    fn quoteRemoveLiquidity(self: @K, token_a: ContractAddress, token_b: ContractAddress, stable: felt252, liquidity: u256) -> (u256,u256);
    fn removeLiquidity(ref self: K, token_a: ContractAddress,token_b: ContractAddress, stable: felt252, liquidity: u256, amount_a_min: u256, amount_b_min: u256, to: ContractAddress, deadline: u64) -> (u256,u256);
    fn getAmountOut(self: @K, amount_in: u256, token_in: ContractAddress, token_out: ContractAddress) -> (u256,felt252);
    fn swapExactTokensForTokensSupportingFeeOnTransferTokens(ref self: K, amount_in: u256, amount_out_min: u256, routes_len: felt252, routes: StarkiProtocol::Route, to: ContractAddress,deadline: u64);,
}

#[starknet::interface]
trait Pair<K> {
    fn approve(ref self: K, spender: ContractAddress, amount: u256) -> felt252;
    fn claimFees(ref self: K) -> (u256,u256);
}

//Contract Interface
#[starknet::interface]
trait IStarkiProtocol<TContractState> {
    fn get_balance(self: @TContractState,address: ContractAddress) -> u128;
    fn deposit(ref self: TContractState,depositor: ContractAddress,amount: u256);
    fn withdraw(ref self: TContractState,address: ContractAddress);
    fn startEpoch(ref self: TContractState);
    fn finishEpoch(ref self: TContractState);
}

#[derive(Serde, Drop)]
struct Route {
    from_address: ContractAddress,
    to_address: ContractAddress,
    stable: felt252,
}

#[starknet::contract]
mod StarkiProtocol {
    use core::option::OptionTrait;
use core::traits::TryInto;
use core::traits::Into;
    use starknet::get_caller_address;
    use starknet::{ContractAddress,};
    use dict::Felt252DictTrait;
    use zeroable::Zeroable;
    use starknet::contract_address_const;
    use starknet::ContractAddressIntoFelt252;
    use starknet::Felt252TryIntoContractAddress;
    use starknet::{get_block_info,get_contract_address};
    use box::BoxTrait;
    use array::ArrayTrait;
    use super::{
        IERC20Dispatcher, IERC20DispatcherTrait,RouterDispatcher,RouterDispatcherTrait,Route
    };

    #[storage]
    struct Storage {
        balances: LegacyMap::<ContractAddress, u128>,
        token: ContractAddress,
        owner: ContractAddress,
        epochActive: bool,
        epochStartTimestamp: u64,
        epochDuration: u64,
        liquidityTokenA: ContractAddress,
        liquidityTokenB: ContractAddress,
        liquidityAmount: u256,
        routerAddress: ContractAddress,
        pairAddress: ContractAddress,
        ticketPrice: u256,
        ticketCount: u256,
        tickets: Array<ContractAddress>
    }



    #[constructor]
    fn constructor(ref self: ContractState,token_address: ContractAddress,owner: ContractAddress){
        self.token.write(token_address);
        self.owner.write(owner);
        self.epochActive.write(false);
        self.tickets.write(ArrayTrait::new());
    }

    #[external(v0)]
    impl StarkiProtocol of super::IStarkiProtocol<ContractState> {
        fn get_balance(self: @ContractState,address: ContractAddress) -> u128{
            self.balances.read(address)
        }

        fn deposit(ref self: ContractState,depositor: ContractAddress,amount: u256){
            let isEpochActive = self.epochActive.read();
            assert(isEpochActive == false,'Cannot deposit during epoch');
            let ticketPrice = self.ticketPrice.read();
            let remainder = amount % ticketPrice;
            assert(remainder == 0,'Invalid amount');
            let totalTicketCount = self.ticketCount.read();
            let boughtTicketCount = amount / ticketPrice;
            let mut tickets = self.tickets.read();
            let callerAddress = get_caller_address();
            
            let mut i: u256 = 0;
            loop {
                if i >= boughtTicketCount {
                    break;
                }
                tickets.append(callerAddress);
                i += 1;
            }

            let boughtTicketCount: u128 = boughtTicketCount.try_into().unwrap();

            let balance = self.balances.read(depositor);
            self.balances.write(depositor,balance+boughtTicketCount);
            let tokenAddr = self.liquidityTokenA.read();
            let contractAddress = get_contract_address();

            IERC20Dispatcher {contract_address: tokenAddr}.transfer_from(depositor,contractAddress,amount);
        }

        fn withdraw(ref self: ContractState,address: ContractAddress){
            let isEpochActive = self.epochActive.read();
            assert(isEpochActive == false,'Cannot withdraw during epoch');

            let callerAddress = get_caller_address();
            let tokenAddr = self.liquidityTokenA.read();
            let balance = self.balances.read(callerAddress);
            self.balances.write(callerAddress,0);

            IERC20Dispatcher {contract_address: tokenAddr}.transfer(address,balance);
        }

        fn startEpoch(ref self: ContractState){
            let isEpochActive = self.epochActive.read();
            assert(isEpochActive == false,'Epoch has not started');
           
            self.epochStartTimestamp.write(self._getBlockTimestamp());
            self.epochActive.write(true); 
            let tokenA = self.liquidityTokenA.read();
            let tokenB = self.liquidityTokenB.read();
            let contract_address = get_contract_address();
            let totalBalance = IERC20Dispatcher {contract_address: self.token.read()}.balance_of(contract_address);

            self._swap(totalBalance/2,tokenA,tokenB);

            let tokenABalance = IERC20Dispatcher {contract_address: self.token.read()}.balance_of(contract_address);
            let tokenBBalance = IERC20Dispatcher {contract_address: self.liquidityTokenB.read()}.balance_of(contract_address);

            self._addLiquidity(tokenABalance,tokenBBalance);      
        } 

        fn finishEpoch(ref self: ContractState){
            let isEpochActive = self.epochActive.read();
            assert(isEpochActive == false,'Cannot finish epoch while not active');
            let blockTimestamp = self._getBlockTimestamp();
            let startTimestamp = self.epochStartTimestamp.read();
            let epochDuration = self.epochDuration.read();
            assert(blockTimestamp - startTimestamp >= epochDuration,'Epoch has not finished');

            let tokenA = self.liquidityTokenA.read();
            let tokenB = self.liquidityTokenB.read();
            let contract_address = get_contract_address();

            let (tokenAReward,tokenBReward) = PairDispatcher {contract_address: self.pairAddress.read()}.claimFees();
            let success = IERC20Dispatcher {contract_address: tokenA}.transfer(contract_address,tokenAReward);
            assert(success == true,'Failed to transfer reward A');
            let success = IERC20Dispatcher {contract_address: tokenB}.transfer(contract_address,tokenBReward);
            assert(success == true,'Failed to transfer reward B');
            self._removeLiquidity();

            let tokenABalance = IERC20Dispatcher {contract_address: tokenA}.balance_of(contract_address);
            let tokenBBalance = IERC20Dispatcher {contract_address: tokenB}.balance_of(contract_address);

            self._swap(tokenBBalance,tokenB,tokenA);   
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _getBlockTimestamp(self: @ContractState) -> u64{
            get_block_info().unbox().block_timestamp
        }

        fn _swap(ref self: ContractState,amount: u256,from: ContractAddress,to: ContractAddress) {
            let deadline = self._getBlockTimestamp();
            let deadline = deadline + 60;

            let (amountOut,stable) = RouterDispatcher {contract_address: self.token.read()}.getAmountOut(amount,from,to);
            let amountOut = (amountOut * 99) / 100;

            let route  = Route {
                from_address: from,
                to_address: to,
                stable: 1,
            };

            IERC20Dispatcher {contract_address: from}.approve(self.routerAddress.read(),amount);
            RouterDispatcher {contract_address: self.routerAddress.read()}.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount,amountOut,1,route,get_contract_address(),deadline);
        }

        fn _addLiquidity(ref self: ContractState,amountA: u256,amountB: u256){
            let tokenA = self.liquidityTokenA.read();
            let tokenB = self.liquidityTokenB.read();

            let (realAmountA,realAmountB,liquidityAmount) = RouterDispatcher {contract_address: self.routerAddress.read()}.quoteAddLiquidity(tokenA,tokenB,1,amountA,amountB);
            let minAmountA = realAmountA * 995 / 1000;
            let minAmountB = realAmountB * 995 / 1000;
            let deadline = self._getBlockTimestamp();
            let deadline = deadline + 60;
            let (addedAmountA,addedAmountB,liquidity) = RouterDispatcher {contract_address: self.routerAddress.read()}.addLiquidity(tokenA,tokenB,1,realAmountA,realAmountB,minAmountA,minAmountB,get_contract_address(),deadline);
            self.liquidityAmount.write(liquidity);
        }

        fn _removeLiquidity(ref self: ContractState){
            let tokenA = self.liquidityTokenA.read();
            let tokenB = self.liquidityTokenB.read();
            let liquidity = self.liquidityAmount.read();
            
            let (realAmountA,realAmountB) = RouterDispatcher {contract_address: self.routerAddress.read()}.quoteRemoveLiquidity(tokenA,tokenB,1,liquidity);
            let minAmountA = realAmountA * 995 / 1000;
            let minAmountB = realAmountB * 995 / 1000;
            let deadline = self._getBlockTimestamp();
            let deadline = deadline + 60;

            PairDispatcher {contract_address: self.pairAddress.read()}.approve(self.routerAddress.read(),liquidity);
            RouterDispatcher {contract_address: self.token.read()}.removeLiquidity(tokenA,tokenB,1,liquidity,minAmountA,minAmountB,get_contract_address(),deadline);
        }
    }
}
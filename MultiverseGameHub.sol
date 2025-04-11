// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MultiverseGameHub is ERC20, ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using Strings for uint256;
    using ECDSA for bytes32;

    // ======================= CORE STATE VARIABLES =======================
    
    // Token Economics
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1 billion tokens
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 10**18; // 100 million tokens
    uint256 public stakingRewardRate = 5; // 5% annual reward
    uint256 public gameRewardRate = 2; // 2% of game fees
    uint256 public referralRewardRate = 10; // 10% of referred user's fees
    
    // Staking
    mapping(address => uint256) public stakedAmount;
    mapping(address => uint256) public stakingStartTime;
    mapping(address => uint256) public lastRewardClaimTime;
    
    // Referrals
    mapping(address => address) public referrer;
    mapping(address => address[]) public referrals;
    mapping(address => uint256) public referralEarnings;
    
    // Liquidity Pool
    struct LiquidityPool {
        uint256 tokenAmount;
        uint256 ethAmount;
        uint256 totalShares;
    }
    LiquidityPool public liquidityPool;
    mapping(address => uint256) public liquidityShares;
    
    // Fee Structure
    uint256 public transactionFee = 25; // 0.25%
    uint256 public stakingFee = 10; // 0.1%
    uint256 public gameFee = 50; // 0.5%
    uint256 public nftMarketplaceFee = 250; // 2.5%
    uint256 public constant FEE_DENOMINATOR = 10000;
    
    // Treasury
    uint256 public treasuryBalance;
    mapping(address => bool) public isTreasuryManager;
    
    // Game State - Basic Definitions
    enum GameStatus { Inactive, Active, Paused, Terminated }
    mapping(uint256 => GameStatus) public gameStatus;
    mapping(uint256 => string) public gameName;
    mapping(uint256 => uint256) public gameFeeRate;
    
    // Player Profiles
    struct PlayerProfile {
        string username;
        uint256 experience;
        uint256 level;
        uint256 reputation;
        uint256 totalGamesPlayed;
        uint256 totalWins;
        bool isActive;
        mapping(uint256 => bool) unlockedAchievements;
        mapping(uint256 => uint256) gameStats;
    }
    mapping(address => PlayerProfile) public players;
    mapping(string => address) public usernameToAddress;
    
    // Achievement System
    struct Achievement {
        string name;
        string description;
        uint256 experienceReward;
        uint256 tokenReward;
        bool isActive;
    }
    mapping(uint256 => Achievement) public achievements;
    uint256 public achievementCount;
    
    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ReferralRegistered(address indexed referrer, address indexed referee);
    event ReferralRewardPaid(address indexed referrer, address indexed referee, uint256 amount);
    event LiquidityAdded(address indexed provider, uint256 tokenAmount, uint256 ethAmount, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 tokenAmount, uint256 ethAmount, uint256 shares);
    event GameCreated(uint256 indexed gameId, string name, uint256 feeRate);
    event GameStatusChanged(uint256 indexed gameId, GameStatus status);
    event PlayerRegistered(address indexed player, string username);
    event ExperienceGained(address indexed player, uint256 amount);
    event LevelUp(address indexed player, uint256 newLevel);
    event AchievementUnlocked(address indexed player, uint256 achievementId);
    event TreasuryWithdrawal(address indexed manager, uint256 amount, string purpose);
    
    // ======================= CONSTRUCTOR =======================
    
    constructor() ERC20("Multiverse Token", "MVT") Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
        treasuryBalance = INITIAL_SUPPLY.div(10); // 10% of initial supply goes to treasury
        _transfer(msg.sender, address(this), treasuryBalance);
        
        // Initialize default achievements
        _createAchievement("First Step", "Register as a player", 100, 10 * 10**18);
        _createAchievement("Game Pioneer", "Play 10 different games", 500, 50 * 10**18);
        _createAchievement("Token Enthusiast", "Stake at least 1000 tokens", 300, 30 * 10**18);
        _createAchievement("Referral Master", "Refer 5 friends", 700, 70 * 10**18);
        _createAchievement("Liquidity Provider", "Add liquidity to the pool", 400, 40 * 10**18);
        
        // Add owner as treasury manager
        isTreasuryManager[msg.sender] = true;
    }
    
    // ======================= TOKEN ECONOMICS FUNCTIONS =======================
    
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // Transfer tokens to contract
        _transfer(msg.sender, address(this), amount);
        
        // Update staking info
        if (stakedAmount[msg.sender] > 0) {
            // Claim pending rewards first
            claimStakingReward();
        } else {
            // New staker
            stakingStartTime[msg.sender] = block.timestamp;
        }
        
        stakedAmount[msg.sender] = stakedAmount[msg.sender].add(amount);
        lastRewardClaimTime[msg.sender] = block.timestamp;
        
        emit Staked(msg.sender, amount);
        
        // Check for achievement
        if (stakedAmount[msg.sender] >= 1000 * 10**18) {
            _unlockAchievement(msg.sender, 2); // "Token Enthusiast" achievement
        }
    }
    
    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        require(stakedAmount[msg.sender] >= amount, "Insufficient staked amount");
        
        // Claim rewards first
        claimStakingReward();
        
        // Update staking info
        stakedAmount[msg.sender] = stakedAmount[msg.sender].sub(amount);
        
        // Transfer tokens back to user
        _transfer(address(this), msg.sender, amount);
        
        emit Unstaked(msg.sender, amount);
    }
    
    function claimStakingReward() public nonReentrant returns (uint256) {
        require(stakedAmount[msg.sender] > 0, "No staked tokens");
        
        uint256 reward = calculateStakingReward(msg.sender);
        require(reward > 0, "No rewards to claim");
        
        // Update claim time
        lastRewardClaimTime[msg.sender] = block.timestamp;
        
        // Mint rewards
        _mint(msg.sender, reward);
        
        emit RewardClaimed(msg.sender, reward);
        
        return reward;
    }
    
    function calculateStakingReward(address user) public view returns (uint256) {
    if (stakedAmount[user] == 0) return 0;
    
    uint256 timeStaked = block.timestamp.sub(lastRewardClaimTime[user]);
    uint256 annualReward = stakedAmount[user].mul(stakingRewardRate).div(100);
    uint256 reward = annualReward.mul(timeStaked).div(365 days);
    
    // Apply fee
    uint256 fee = reward.mul(stakingFee).div(FEE_DENOMINATOR);
    uint256 netReward = reward.sub(fee);
    
    // ลบบรรทัดนี้ออก เพราะเป็นการแก้ไขสถานะในฟังก์ชัน view
    // treasuryBalance = treasuryBalance.add(fee);
    
    return netReward;
}
    
    function registerReferral(address referrerAddress) external {
        require(referrerAddress != msg.sender, "Cannot refer yourself");
        require(referrerAddress != address(0), "Invalid referrer address");
        require(referrer[msg.sender] == address(0), "Already has a referrer");
        require(balanceOf(referrerAddress) > 0, "Referrer must hold tokens");
        
        referrer[msg.sender] = referrerAddress;
        referrals[referrerAddress].push(msg.sender);
        
        emit ReferralRegistered(referrerAddress, msg.sender);
        
        // Check for achievement
        if (referrals[referrerAddress].length >= 5) {
            _unlockAchievement(referrerAddress, 3); // "Referral Master" achievement
        }
    }
    
    function payReferralReward(address user, uint256 amount) internal {
        address userReferrer = referrer[user];
        if (userReferrer != address(0)) {
            uint256 referralReward = amount.mul(referralRewardRate).div(100);
            referralEarnings[userReferrer] = referralEarnings[userReferrer].add(referralReward);
            _transfer(address(this), userReferrer, referralReward);
            
            emit ReferralRewardPaid(userReferrer, user, referralReward);
        }
    }
    
    function addLiquidity() external payable nonReentrant {
        require(msg.value > 0, "ETH amount must be greater than zero");
        uint256 tokenAmount = msg.value.mul(10); // 1 ETH = 10 tokens (example rate)
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient token balance");
        
        // Transfer tokens to contract
        _transfer(msg.sender, address(this), tokenAmount);
        
        // Calculate shares
        uint256 shares;
        if (liquidityPool.totalShares == 0) {
            shares = 1000 * 10**18; // Initial shares
        } else {
            shares = msg.value.mul(liquidityPool.totalShares).div(liquidityPool.ethAmount);
        }
        
        // Update liquidity pool
        liquidityPool.tokenAmount = liquidityPool.tokenAmount.add(tokenAmount);
        liquidityPool.ethAmount = liquidityPool.ethAmount.add(msg.value);
        liquidityPool.totalShares = liquidityPool.totalShares.add(shares);
        
        // Update user shares
        liquidityShares[msg.sender] = liquidityShares[msg.sender].add(shares);
        
        emit LiquidityAdded(msg.sender, tokenAmount, msg.value, shares);
        
        // Unlock achievement
        _unlockAchievement(msg.sender, 4); // "Liquidity Provider" achievement
    }
    
    function removeLiquidity(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "Share amount must be greater than zero");
        require(liquidityShares[msg.sender] >= shareAmount, "Insufficient shares");
        
        // Calculate token and ETH amounts
        uint256 tokenAmount = shareAmount.mul(liquidityPool.tokenAmount).div(liquidityPool.totalShares);
        uint256 ethAmount = shareAmount.mul(liquidityPool.ethAmount).div(liquidityPool.totalShares);
        
        // Update liquidity pool
        liquidityPool.tokenAmount = liquidityPool.tokenAmount.sub(tokenAmount);
        liquidityPool.ethAmount = liquidityPool.ethAmount.sub(ethAmount);
        liquidityPool.totalShares = liquidityPool.totalShares.sub(shareAmount);
        
        // Update user shares
        liquidityShares[msg.sender] = liquidityShares[msg.sender].sub(shareAmount);
        
        // Transfer assets back to user
        _transfer(address(this), msg.sender, tokenAmount);
        payable(msg.sender).transfer(ethAmount);
        
        emit LiquidityRemoved(msg.sender, tokenAmount, ethAmount, shareAmount);
    }
    
    function swap(bool tokenToEth, uint256 amount) external payable nonReentrant {
        require(amount > 0, "Amount must be greater than zero");
        
        uint256 fee = amount.mul(transactionFee).div(FEE_DENOMINATOR);
        uint256 amountAfterFee = amount.sub(fee);
        treasuryBalance = treasuryBalance.add(fee);
        
        if (tokenToEth) {
            // Swap tokens for ETH
            require(balanceOf(msg.sender) >= amount, "Insufficient token balance");
            uint256 ethOutput = calculateSwapOutput(amountAfterFee, liquidityPool.tokenAmount, liquidityPool.ethAmount);
            require(ethOutput <= liquidityPool.ethAmount, "Insufficient liquidity");
            
            // Update pool
            _transfer(msg.sender, address(this), amount);
            liquidityPool.tokenAmount = liquidityPool.tokenAmount.add(amountAfterFee);
            liquidityPool.ethAmount = liquidityPool.ethAmount.sub(ethOutput);
            
            // Send ETH to user
            payable(msg.sender).transfer(ethOutput);
            
            // Pay referral reward
            payReferralReward(msg.sender, fee);
        } else {
            // Swap ETH for tokens
            require(msg.value >= amount, "Insufficient ETH sent");
            uint256 tokenOutput = calculateSwapOutput(amountAfterFee, liquidityPool.ethAmount, liquidityPool.tokenAmount);
            require(tokenOutput <= liquidityPool.tokenAmount, "Insufficient liquidity");
            
            // Update pool
            liquidityPool.ethAmount = liquidityPool.ethAmount.add(amountAfterFee);
            liquidityPool.tokenAmount = liquidityPool.tokenAmount.sub(tokenOutput);
            
            // Send tokens to user
            _transfer(address(this), msg.sender, tokenOutput);
            
            // Refund excess ETH
            if (msg.value > amount) {
                payable(msg.sender).transfer(msg.value.sub(amount));
            }
            
            // Pay referral reward
            payReferralReward(msg.sender, fee);
        }
    }
    
    function calculateSwapOutput(uint256 inputAmount, uint256 inputReserve, uint256 outputReserve) 
        public pure returns (uint256) {
        require(inputReserve > 0 && outputReserve > 0, "Invalid reserves");
        
        // Using x * y = k formula
        uint256 inputAmountWithFee = inputAmount.mul(997); // 0.3% swap fee
        uint256 numerator = inputAmountWithFee.mul(outputReserve);
        uint256 denominator = inputReserve.mul(1000).add(inputAmountWithFee);
        
        return numerator.div(denominator);
    }
    
    // ======================= PLAYER PROFILE FUNCTIONS =======================
    
    function registerPlayer(string memory username) external {
        require(bytes(username).length > 0 && bytes(username).length <= 32, "Invalid username length");
        require(bytes(players[msg.sender].username).length == 0, "Already registered");
        require(usernameToAddress[username] == address(0), "Username already taken");
        
        players[msg.sender].username = username;
        players[msg.sender].experience = 0;
        players[msg.sender].level = 1;
        players[msg.sender].reputation = 100;
        players[msg.sender].isActive = true;
        
        usernameToAddress[username] = msg.sender;
        
        emit PlayerRegistered(msg.sender, username);
        
        // Unlock first achievement
        _unlockAchievement(msg.sender, 0); // "First Step" achievement
    }
    
    function addExperience(address player, uint256 amount) internal {
        require(bytes(players[player].username).length > 0, "Player not registered");
        
        players[player].experience = players[player].experience.add(amount);
        
        // Check for level up
        uint256 experienceForNextLevel = players[player].level.mul(1000);
        if (players[player].experience >= experienceForNextLevel) {
            players[player].level = players[player].level.add(1);
            
            // Reward for level up
            uint256 levelUpReward = players[player].level.mul(5 * 10**18); // 5 tokens per level
            _mint(player, levelUpReward);
            
            emit LevelUp(player, players[player].level);
        }
        
        emit ExperienceGained(player, amount);
    }
    
    // ======================= ACHIEVEMENT SYSTEM FUNCTIONS =======================
    
    function _createAchievement(
        string memory name,
        string memory description,
        uint256 experienceReward,
        uint256 tokenReward
    ) internal {
        achievements[achievementCount] = Achievement({
            name: name,
            description: description,
            experienceReward: experienceReward,
            tokenReward: tokenReward,
            isActive: true
        });
        
        achievementCount++;
    }
    
    function _unlockAchievement(address player, uint256 achievementId) internal {
        require(achievementId < achievementCount, "Achievement does not exist");
        require(!players[player].unlockedAchievements[achievementId], "Achievement already unlocked");
        require(achievements[achievementId].isActive, "Achievement is inactive");
        
        players[player].unlockedAchievements[achievementId] = true;
        
        // Add experience
        addExperience(player, achievements[achievementId].experienceReward);
        
        // Reward tokens
        _mint(player, achievements[achievementId].tokenReward);
        
        emit AchievementUnlocked(player, achievementId);
    }
    
    // ======================= TREASURY MANAGEMENT =======================
    
    function addTreasuryManager(address manager) external onlyOwner {
        isTreasuryManager[manager] = true;
    }
    
    function removeTreasuryManager(address manager) external onlyOwner {
        isTreasuryManager[manager] = false;
    }
    
    function withdrawFromTreasury(uint256 amount, string memory purpose) external nonReentrant {
        require(isTreasuryManager[msg.sender], "Not a treasury manager");
        require(amount > 0, "Amount must be greater than zero");
        require(treasuryBalance >= amount, "Insufficient treasury balance");
        
        treasuryBalance = treasuryBalance.sub(amount);
        _transfer(address(this), msg.sender, amount);
        
        emit TreasuryWithdrawal(msg.sender, amount, purpose);
    }
    
    // ======================= GAME MANAGEMENT =======================
    
    function createGame(uint256 gameId, string memory name, uint256 feeRate) external onlyOwner {
        require(bytes(gameName[gameId]).length == 0, "Game ID already exists");
        require(bytes(name).length > 0, "Name cannot be empty");
        require(feeRate <= 1000, "Fee rate too high"); // Max 10%
        
        gameName[gameId] = name;
        gameFeeRate[gameId] = feeRate;
        gameStatus[gameId] = GameStatus.Active;
        
        emit GameCreated(gameId, name, feeRate);
    }
    
    function setGameStatus(uint256 gameId, GameStatus status) external onlyOwner {
        require(bytes(gameName[gameId]).length > 0, "Game does not exist");
        
        gameStatus[gameId] = status;
        
        emit GameStatusChanged(gameId, status);
    }
    
    // Base function for recording a game played
    function recordGamePlayed(address player, uint256 gameId, bool won, uint256 score) internal {
        require(bytes(players[player].username).length > 0, "Player not registered");
        require(bytes(gameName[gameId]).length > 0, "Game does not exist");
        require(gameStatus[gameId] == GameStatus.Active, "Game is not active");
        
        players[player].totalGamesPlayed++;
        if (won) {
            players[player].totalWins++;
        }
        
        players[player].gameStats[gameId] = score;
        
        // Add experience based on game played
        uint256 experienceGained = won ? 50 : 10; // More exp for winning
        addExperience(player, experienceGained);
        
        // Check for achievement
        uint256 uniqueGamesPlayed = 0;
        for (uint256 i = 0; i < 100; i++) { // Assuming max 100 games
            if (players[player].gameStats[i] > 0) {
                uniqueGamesPlayed++;
            }
        }
        
        if (uniqueGamesPlayed >= 10) {
            _unlockAchievement(player, 1); // "Game Pioneer" achievement
        }
    }
    
    // ======================= FALLBACK & RECEIVE =======================
    
    receive() external payable {
        // Auto-convert received ETH to tokens and add to sender's balance
        uint256 tokenAmount = msg.value.mul(9); // 1 ETH = 9 tokens (slightly worse than addLiquidity)
        _mint(msg.sender, tokenAmount);
    }
    
    fallback() external payable {
        // Same as receive
        uint256 tokenAmount = msg.value.mul(9);
        _mint(msg.sender, tokenAmount);
    }


// ======================= MINI GAMES SYSTEM =======================

// Game Types
enum GameType {
    None,
    DiceRoll,
    CoinFlip,
    NumberGuess,
    RockPaperScissors,
    CardDraw,
    SlotMachine,
    RandomTreasure,
    LuckyLottery,
    BattleArena,
    QuestChallenge
}

// Game Result States
enum GameResultState {
    None,
    Win,
    Loss,
    Draw,
    Pending,
    Cancelled,
    Expired
}

// Game Session Structure
struct GameSession {
    uint256 gameId;
    GameType gameType;
    address player;
    uint256 betAmount;
    uint256 potentialReward;
    uint256 timestamp;
    bytes32 randomSeed;
    GameResultState result;
    bool rewardClaimed;
    uint256 gameSpecificData;
    uint256[] moveHistory;
}

// Leaderboard Structure
struct LeaderboardEntry {
    address player;
    uint256 score;
    uint256 timestamp;
}

// Game Statistics
struct GameStats {
    uint256 totalGamesPlayed;
    uint256 totalBetAmount;
    uint256 totalRewardsPaid;
    uint256 totalPlayers;
    uint256 highestWin;
    address highestWinner;
}

// Mappings for Game Data
mapping(bytes32 => GameSession) public gameSessions;
mapping(uint256 => GameStats) public gameTypeStats;
mapping(uint256 => LeaderboardEntry[]) public gameLeaderboards;
mapping(address => bytes32[]) public playerGameHistory;
mapping(bytes32 => uint256) public gameIdToIndex;
mapping(uint256 => uint256) public gameTypeMinimumBet;
mapping(uint256 => uint256) public gameTypePayout;

// Game Settings
uint256 public maxBetAmount = 100000 * 10**18; // 100,000 tokens
uint256 public minBetAmount = 10 * 10**18; // 10 tokens
uint256 public gameSessionTimeout = 1 hours;
uint256 public maxLeaderboardEntries = 10;

// Game events
event GameSessionCreated(bytes32 indexed sessionId, uint256 gameType, address indexed player, uint256 betAmount);
event GameResult(bytes32 indexed sessionId, address indexed player, GameResultState result, uint256 reward);
event RewardClaimed(bytes32 indexed sessionId, address indexed player, uint256 amount);
event GameMove(bytes32 indexed sessionId, address indexed player, uint256 moveType, uint256 moveValue);
event LeaderboardUpdated(uint256 indexed gameType, address indexed player, uint256 score);

// Random Number Generation Helpers
uint256 private nonce = 0;
bytes32 private lastBlockHash;

// Function to create a game session
function createGameSession(
    uint256 gameTypeId,
    uint256 betAmount
) external nonReentrant returns (bytes32) {
    require(gameTypeId > 0 && gameTypeId <= uint256(GameType.QuestChallenge), "Invalid game type");
    require(betAmount >= minBetAmount, "Bet amount too small");
    require(betAmount <= maxBetAmount, "Bet amount too large");
    require(gameStatus[gameTypeId] == GameStatus.Active, "Game not active");
    require(betAmount <= balanceOf(msg.sender), "Insufficient balance");
    
    // Calculate game fee
    uint256 fee = betAmount.mul(gameFee).div(FEE_DENOMINATOR);
    uint256 betAfterFee = betAmount.sub(fee);
    
    // Transfer bet + fee from player to contract
    _transfer(msg.sender, address(this), betAmount);
    
    // Add fee to treasury
    treasuryBalance = treasuryBalance.add(fee);
    
    // Pay referral if applicable
    payReferralReward(msg.sender, fee);
    
    // Generate unique session ID
    bytes32 sessionId = keccak256(abi.encodePacked(
        msg.sender,
        gameTypeId,
        betAmount,
        block.timestamp,
        nonce++
    ));
    
    // Create game session
    gameSessions[sessionId] = GameSession({
        gameId: gameTypeId,
        gameType: GameType(gameTypeId),
        player: msg.sender,
        betAmount: betAfterFee,
        potentialReward: calculatePotentialReward(gameTypeId, betAfterFee),
        timestamp: block.timestamp,
        randomSeed: bytes32(0),
        result: GameResultState.Pending,
        rewardClaimed: false,
        gameSpecificData: 0,
        moveHistory: new uint256[](0)
    });
    
    // Update player's game history
    playerGameHistory[msg.sender].push(sessionId);
    gameIdToIndex[sessionId] = playerGameHistory[msg.sender].length - 1;
    
    // Update game stats
    gameTypeStats[gameTypeId].totalGamesPlayed++;
    gameTypeStats[gameTypeId].totalBetAmount = gameTypeStats[gameTypeId].totalBetAmount.add(betAfterFee);
    
    // If first time playing, increment total players
    if (players[msg.sender].gameStats[gameTypeId] == 0) {
        gameTypeStats[gameTypeId].totalPlayers++;
    }
    
    // Record game played
    recordGamePlayed(msg.sender, gameTypeId, false, 0);
    
    emit GameSessionCreated(sessionId, gameTypeId, msg.sender, betAfterFee);
    
    return sessionId;
}

// Calculate potential reward based on game type and bet amount
function calculatePotentialReward(uint256 gameTypeId, uint256 betAmount) public view returns (uint256) {
    uint256 payoutMultiplier = gameTypePayout[gameTypeId];
    if (payoutMultiplier == 0) {
        // Default multipliers if not set
        if (gameTypeId == uint256(GameType.DiceRoll)) return betAmount.mul(2);
        if (gameTypeId == uint256(GameType.CoinFlip)) return betAmount.mul(198).div(100); // 1.98x
        if (gameTypeId == uint256(GameType.NumberGuess)) return betAmount.mul(5); // 5x
        if (gameTypeId == uint256(GameType.RockPaperScissors)) return betAmount.mul(19).div(10); // 1.9x
        if (gameTypeId == uint256(GameType.CardDraw)) return betAmount.mul(3); // 3x
        if (gameTypeId == uint256(GameType.SlotMachine)) return betAmount.mul(10); // 10x for jackpot
        if (gameTypeId == uint256(GameType.RandomTreasure)) return betAmount.mul(5); // 5x
        if (gameTypeId == uint256(GameType.LuckyLottery)) return betAmount.mul(50); // 50x
        if (gameTypeId == uint256(GameType.BattleArena)) return betAmount.mul(25).div(10); // 2.5x
        if (gameTypeId == uint256(GameType.QuestChallenge)) return betAmount.mul(4); // 4x
        return betAmount.mul(2); // Default 2x
    }
    return betAmount.mul(payoutMultiplier).div(100);
}

// Claim reward for a won game
function claimGameReward(bytes32 sessionId) external nonReentrant {
    GameSession storage session = gameSessions[sessionId];
    require(session.player == msg.sender, "Not your game session");
    require(session.result == GameResultState.Win, "Game not won");
    require(!session.rewardClaimed, "Reward already claimed");
    
    session.rewardClaimed = true;
    
    // Update game stats
    gameTypeStats[uint256(session.gameType)].totalRewardsPaid = 
        gameTypeStats[uint256(session.gameType)].totalRewardsPaid.add(session.potentialReward);
        
    // Check if this is the highest win
    if (session.potentialReward > gameTypeStats[uint256(session.gameType)].highestWin) {
        gameTypeStats[uint256(session.gameType)].highestWin = session.potentialReward;
        gameTypeStats[uint256(session.gameType)].highestWinner = msg.sender;
    }
    
    // Transfer reward to player
    _transfer(address(this), msg.sender, session.potentialReward);
    
    emit RewardClaimed(sessionId, msg.sender, session.potentialReward);
}

// Generate a random number (using block hash for simplicity - would use chainlink VRF in production)
function getRandomNumber(bytes32 sessionId, uint256 max) internal returns (uint256) {
    nonce++;
    lastBlockHash = blockhash(block.number - 1);
    return uint256(keccak256(abi.encodePacked(
        lastBlockHash,
        block.timestamp,
        msg.sender,
        nonce,
        sessionId
    ))) % max;
}

// Function to submit a game move - common function for multiple games
function submitGameMove(bytes32 sessionId, uint256 moveType, uint256 moveValue) external nonReentrant {
    GameSession storage session = gameSessions[sessionId];
    require(session.player == msg.sender, "Not your game session");
    require(session.result == GameResultState.Pending, "Game already completed");
    require(block.timestamp <= session.timestamp + gameSessionTimeout, "Game session expired");
    
    // Store move in history
    session.moveHistory.push((moveType << 128) | moveValue);
    
    emit GameMove(sessionId, msg.sender, moveType, moveValue);
    
    // Process game based on game type
    if (session.gameType == GameType.DiceRoll) {
        processDiceRollGame(sessionId, moveValue);
    } else if (session.gameType == GameType.CoinFlip) {
        processCoinFlipGame(sessionId, moveValue);
    } else if (session.gameType == GameType.NumberGuess) {
        processNumberGuessGame(sessionId, moveValue);
    } else if (session.gameType == GameType.RockPaperScissors) {
        processRockPaperScissorsGame(sessionId, moveValue);
    } else if (session.gameType == GameType.CardDraw) {
        processCardDrawGame(sessionId, moveValue);
    } else if (session.gameType == GameType.SlotMachine) {
        processSlotMachineGame(sessionId);
    } else if (session.gameType == GameType.RandomTreasure) {
        processRandomTreasureGame(sessionId);
    } else if (session.gameType == GameType.LuckyLottery) {
        processLuckyLotteryGame(sessionId, moveValue);
    } else if (session.gameType == GameType.BattleArena) {
        processBattleArenaGame(sessionId, moveType, moveValue);
    } else if (session.gameType == GameType.QuestChallenge) {
        processQuestChallengeGame(sessionId, moveType, moveValue);
    }
}

// ======================= INDIVIDUAL GAME IMPLEMENTATIONS =======================

// Implementation for Dice Roll Game
function processDiceRollGame(bytes32 sessionId, uint256 playerGuess) internal {
    require(playerGuess >= 1 && playerGuess <= 6, "Guess must be between 1 and 6");
    
    GameSession storage session = gameSessions[sessionId];
    
    // Roll the dice (1-6)
    uint256 diceResult = getRandomNumber(sessionId, 6) + 1;
    session.gameSpecificData = diceResult;
    
    // Determine game result
    if (diceResult == playerGuess) {
        session.result = GameResultState.Win;
        updateLeaderboard(uint256(GameType.DiceRoll), session.player, session.potentialReward);
    } else {
        session.result = GameResultState.Loss;
    }
    
    // Update player stats
    bool won = (session.result == GameResultState.Win);
    recordGamePlayed(session.player, uint256(session.gameType), won, diceResult);
    
    emit GameResult(sessionId, session.player, session.result, won ? session.potentialReward : 0);
}

// Implementation for Coin Flip Game
function processCoinFlipGame(bytes32 sessionId, uint256 playerGuess) internal {
    require(playerGuess == 0 || playerGuess == 1, "Guess must be 0 (Heads) or 1 (Tails)");
    
    GameSession storage session = gameSessions[sessionId];
    
    // Flip the coin (0=Heads, 1=Tails)
    uint256 coinResult = getRandomNumber(sessionId, 2);
    session.gameSpecificData = coinResult;
    
    // Determine game result
    if (coinResult == playerGuess) {
        session.result = GameResultState.Win;
        updateLeaderboard(uint256(GameType.CoinFlip), session.player, session.potentialReward);
    } else {
        session.result = GameResultState.Loss;
    }
    
    // Update player stats
    bool won = (session.result == GameResultState.Win);
    recordGamePlayed(session.player, uint256(session.gameType), won, coinResult);
    
    emit GameResult(sessionId, session.player, session.result, won ? session.potentialReward : 0);
}

// Implementation for Number Guess Game
function processNumberGuessGame(bytes32 sessionId, uint256 playerGuess) internal {
    require(playerGuess >= 1 && playerGuess <= 10, "Guess must be between 1 and 10");
    
    GameSession storage session = gameSessions[sessionId];
    
    // Generate random number (1-10)
    uint256 correctNumber = getRandomNumber(sessionId, 10) + 1;
    session.gameSpecificData = correctNumber;
    
    // Determine game result
    if (correctNumber == playerGuess) {
        session.result = GameResultState.Win;
        updateLeaderboard(uint256(GameType.NumberGuess), session.player, session.potentialReward);
    } else {
        session.result = GameResultState.Loss;
    }
    
    // Update player stats
    bool won = (session.result == GameResultState.Win);
    recordGamePlayed(session.player, uint256(session.gameType), won, correctNumber);
    
    emit GameResult(sessionId, session.player, session.result, won ? session.potentialReward : 0);
}

// Implementation for Rock Paper Scissors Game
function processRockPaperScissorsGame(bytes32 sessionId, uint256 playerMove) internal {
    require(playerMove >= 0 && playerMove <= 2, "Move must be 0 (Rock), 1 (Paper), or 2 (Scissors)");
    
    GameSession storage session = gameSessions[sessionId];
    
    // Generate computer move (0=Rock, 1=Paper, 2=Scissors)
    uint256 computerMove = getRandomNumber(sessionId, 3);
    session.gameSpecificData = computerMove;
    
    // Determine game result
    // Rock beats Scissors, Scissors beats Paper, Paper beats Rock
    if (playerMove == computerMove) {
        session.result = GameResultState.Draw;
        // Return bet amount for a draw
        _transfer(address(this), session.player, session.betAmount);
    } else if (
        (playerMove == 0 && computerMove == 2) || // Rock beats Scissors
        (playerMove == 1 && computerMove == 0) || // Paper beats Rock
        (playerMove == 2 && computerMove == 1)    // Scissors beats Paper
    ) {
        session.result = GameResultState.Win;
        updateLeaderboard(uint256(GameType.RockPaperScissors), session.player, session.potentialReward);
    } else {
        session.result = GameResultState.Loss;
    }
    
    // Update player stats
    bool won = (session.result == GameResultState.Win);
    recordGamePlayed(session.player, uint256(session.gameType), won, playerMove * 10 + computerMove);
    
    emit GameResult(sessionId, session.player, session.result, 
        session.result == GameResultState.Win ? session.potentialReward : 
        session.result == GameResultState.Draw ? session.betAmount : 0);
}

// Implementation for Card Draw Game
function processCardDrawGame(bytes32 sessionId, uint256 playerCardGuess) internal {
    require(playerCardGuess >= 1 && playerCardGuess <= 13, "Card value must be between 1 and 13");
    
    GameSession storage session = gameSessions[sessionId];
    
    // Draw random card (1-13 value)
    uint256 drawnCard = getRandomNumber(sessionId, 13) + 1;
    session.gameSpecificData = drawnCard;
    
    // Player wins if their card is higher
    if (playerCardGuess > drawnCard) {
        session.result = GameResultState.Win;
        updateLeaderboard(uint256(GameType.CardDraw), session.player, session.potentialReward);
    } else {
        session.result = GameResultState.Loss;
    }
    
    // Update player stats
    bool won = (session.result == GameResultState.Win);
    recordGamePlayed(session.player, uint256(session.gameType), won, playerCardGuess * 100 + drawnCard);
    
    emit GameResult(sessionId, session.player, session.result, won ? session.potentialReward : 0);
}

// Implementation for Slot Machine Game
function processSlotMachineGame(bytes32 sessionId) internal {
    GameSession storage session = gameSessions[sessionId];
    
    // Generate 3 random slot symbols (0-9)
    uint256 slot1 = getRandomNumber(sessionId, 10);
    uint256 slot2 = getRandomNumber(keccak256(abi.encodePacked(sessionId, "slot2")), 10);
    uint256 slot3 = getRandomNumber(keccak256(abi.encodePacked(sessionId, "slot3")), 10);
    
    // Store the results
    session.gameSpecificData = (slot1 << 16) | (slot2 << 8) | slot3;
    
    // Determine payouts based on combinations
    if (slot1 == slot2 && slot2 == slot3) {
        // Jackpot - all 3 match
        session.result = GameResultState.Win;
        // Bonus multiplier for special numbers
        if (slot1 == 7) {
            session.potentialReward = session.betAmount.mul(15); // 15x for 777
        } else {
            session.potentialReward = session.betAmount.mul(10); // 10x for other triples
        }
        updateLeaderboard(uint256(GameType.SlotMachine), session.player, session.potentialReward);
    } else if (slot1 == slot2 || slot2 == slot3 || slot1 == slot3) {
        // Two matching symbols
        session.result = GameResultState.Win;
        session.potentialReward = session.betAmount.mul(3).div(2); // 1.5x for pairs
        updateLeaderboard(uint256(GameType.SlotMachine), session.player, session.potentialReward);
    } else {
        session.result = GameResultState.Loss;
    }
    
    // Update player stats
    bool won = (session.result == GameResultState.Win);
    recordGamePlayed(session.player, uint256(session.gameType), won, session.gameSpecificData);
    
    emit GameResult(sessionId, session.player, session.result, won ? session.potentialReward : 0);
}

// Implementation for Random Treasure Game
function processRandomTreasureGame(bytes32 sessionId) internal {
    GameSession storage session = gameSessions[sessionId];
    
    // Generate random number to determine treasure value (0-99)
    uint256 treasureValue = getRandomNumber(sessionId, 100);
    session.gameSpecificData = treasureValue;
    
    // Different reward tiers based on rarity
    if (treasureValue < 50) {
        // 50% chance of small win (1.2x)
        session.result = GameResultState.Win;
        session.potentialReward = session.betAmount.mul(12).div(10);
    } else if (treasureValue < 80) {
        // 30% chance of medium win (2x)
        session.result = GameResultState.Win;
        session.potentialReward = session.betAmount.mul(2);
    } else if (treasureValue < 95) {
        // 15% chance of large win (3x)
        session.result = GameResultState.Win;
        session.potentialReward = session.betAmount.mul(3);
    } else if (treasureValue < 99) {
        // 4% chance of jackpot (5x)
        session.result = GameResultState.Win;
        session.potentialReward = session.betAmount.mul(5);
    } else {
        // 1% chance of mega jackpot (10x)
        session.result = GameResultState.Win;
        session.potentialReward = session.betAmount.mul(10);
    }
    
    if (session.result == GameResultState.Win) {
        updateLeaderboard(uint256(GameType.RandomTreasure), session.player, session.potentialReward);
    }
    
    // Update player stats
    recordGamePlayed(session.player, uint256(session.gameType), true, treasureValue);
    
    emit GameResult(sessionId, session.player, session.result, session.potentialReward);
}

// Implementation for Lucky Lottery Game
function processLuckyLotteryGame(bytes32 sessionId, uint256 lotteryNumber) internal {
    require(lotteryNumber >= 1 && lotteryNumber <= 100, "Lottery number must be between 1 and 100");
    
    GameSession storage session = gameSessions[sessionId];
    
    // Generate winning number (1-100)
    uint256 winningNumber = getRandomNumber(sessionId, 100) + 1;
    session.gameSpecificData = winningNumber;
    
    // Determine game result
    if (lotteryNumber == winningNumber) {
        session.result = GameResultState.Win;
        updateLeaderboard(uint256(GameType.LuckyLottery), session.player, session.potentialReward);
    } else {
        session.result = GameResultState.Loss;
    }
    
    // Update player stats
    bool won = (session.result == GameResultState.Win);
    recordGamePlayed(session.player, uint256(session.gameType), won, lotteryNumber * 1000 + winningNumber);
    
    emit GameResult(sessionId, session.player, session.result, won ? session.potentialReward : 0);
}

// Implementation for Battle Arena Game (more complex with multiple moves)
function processBattleArenaGame(bytes32 sessionId, uint256 moveType, uint256 moveValue) internal {
    GameSession storage session = gameSessions[sessionId];
    
    // Check if this is a new battle or a continuation
    if (session.moveHistory.length == 1) {
        // New battle - initialize character stats
        // Format: health (16 bits) | attack (8 bits) | defense (8 bits) | speed (8 bits)
        uint256 playerHealth = 100;
        uint256 playerAttack = 10 + (moveValue % 10); // Slight variability based on moveValue
        uint256 playerDefense = 5 + (moveValue % 5);
        uint256 playerSpeed = 7 + (moveValue % 7);
        
        uint256 enemyHealth = 120;
        uint256 enemyAttack = 8 + getRandomNumber(sessionId, 5);
        uint256 enemyDefense = 6 + getRandomNumber(keccak256(abi.encodePacked(sessionId, "def")), 4);
        uint256 enemySpeed = 5 + getRandomNumber(keccak256(abi.encodePacked(sessionId, "spd")), 5);
        
        // Pack stats into gameSpecificData
        session.gameSpecificData = (playerHealth << 112) | (playerAttack << 96) | (playerDefense << 80) | (playerSpeed << 64) |
                                 (enemyHealth << 48) | (enemyAttack << 32) | (enemyDefense << 16) | enemySpeed;
        
        // More turns will be processed when player submits more moves
        return;
    }
    
    // Unpack current battle state
    uint256 playerHealth = (session.gameSpecificData >> 112) & 0xFFFF;
    uint256 playerAttack = (session.gameSpecificData >> 96) & 0xFF;
    uint256 playerDefense = (session.gameSpecificData >> 80) & 0xFF;
    uint256 playerSpeed = (session.gameSpecificData >> 64) & 0xFF;
    
    uint256 enemyHealth = (session.gameSpecificData >> 48) & 0xFFFF;
    uint256 enemyAttack = (session.gameSpecificData >> 32) & 0xFF;
    uint256 enemyDefense = (session.gameSpecificData >> 16) & 0xFF;
    uint256 enemySpeed = session.gameSpecificData & 0xFF;
    
    // Process player move
    if (moveType == 0) { // Attack
        uint256 damage = playerAttack > enemyDefense ? playerAttack - enemyDefense : 1;
        enemyHealth = enemyHealth > damage ? enemyHealth - damage : 0;
    } else if (moveType == 1) { // Defend
        playerDefense += 3;
    } else if (moveType == 2) { // Special attack
        if (moveValue % 3 == 0) {
            uint256 damage = (playerAttack * 2) > enemyDefense ? (playerAttack * 2) - enemyDefense : 1;
            enemyHealth = enemyHealth > damage ? enemyHealth - damage : 0;
        }
    }
    
    // Process enemy move if still alive
    if (enemyHealth > 0) {
        uint256 enemyMoveType = getRandomNumber(keccak256(abi.encodePacked(sessionId, session.moveHistory.length)), 3);
        
        if (enemyMoveType == 0) { // Attack
            uint256 damage = enemyAttack > playerDefense ? enemyAttack - playerDefense : 1;
            playerHealth = playerHealth > damage ? playerHealth - damage : 0;
        } else if (enemyMoveType == 1) { // Defend
            enemyDefense += 2;
        } else if (enemyMoveType == 2) { // Special attack
            if (getRandomNumber(keccak256(abi.encodePacked(sessionId, "special", session.moveHistory.length)), 4) == 0) {
                uint256 damage = (enemyAttack * 2) > playerDefense ? (enemyAttack * 2) - playerDefense : 1;
                playerHealth = playerHealth > damage ? playerHealth - damage : 0;
            }
        }
    }
    
    // Update battle state
    session.gameSpecificData = (playerHealth << 112) | (playerAttack << 96) | (playerDefense << 80) | (playerSpeed << 64) |
                             (enemyHealth << 48) | (enemyAttack << 32) | (enemyDefense << 16) | enemySpeed;
    
    // Check if battle is over
    if (playerHealth == 0) {
        session.result = GameResultState.Loss;
        recordGamePlayed(session.player, uint256(session.gameType), false, session.moveHistory.length);
        emit GameResult(sessionId, session.player, session.result, 0);
    } else if (enemyHealth == 0) {
        session.result = GameResultState.Win;
        updateLeaderboard(uint256(GameType.BattleArena), session.player, session.potentialReward);
        recordGamePlayed(session.player, uint256(session.gameType), true, session.moveHistory.length);
        emit GameResult(sessionId, session.player, session.result, session.potentialReward);
    }
    // If neither health is 0, the battle continues
}

// Implementation for Quest Challenge Game
function processQuestChallengeGame(bytes32 sessionId, uint256 pathChoice, uint256 actionValue) internal {
    GameSession storage session = gameSessions[sessionId];
    
    // Check current quest stage
    uint256 currentStage = session.moveHistory.length - 1; // First move was already registered
    
    // Process stage outcome based on path choice
    if (currentStage == 0) {
        // First quest stage (path selection)
        session.gameSpecificData = pathChoice; // Store selected path
        
        // Different paths have different success chances
        if (pathChoice == 0) { // Easy path
            // 70% success chance
            if (getRandomNumber(sessionId, 100) < 70) {
                // Success, move to next stage
                return;
            } else {
                session.result = GameResultState.Loss;
            }
        } else if (pathChoice == 1) { // Medium path
            // 50% success chance
            if (getRandomNumber(sessionId, 100) < 50) {
                // Success, move to next stage
                return;
            } else {
                session.result = GameResultState.Loss;
            }
        } else if (pathChoice == 2) { // Hard path
            // 30% success chance
            if (getRandomNumber(sessionId, 100) < 30) {
                // Success, move to next stage
                return;
            } else {
                session.result = GameResultState.Loss;
            }
        }
    } else if (currentStage == 1) {
        // Second quest stage
        uint256 selectedPath = session.gameSpecificData;
        
        // Different challenges based on selected path
        if (selectedPath == 0) { // Easy path - riddle
            // actionValue is the riddle answer (1-5)
            uint256 correctAnswer = getRandomNumber(keccak256(abi.encodePacked(sessionId, "riddle")), 5) + 1;
            if (actionValue == correctAnswer) {
                // Correct answer, move to next stage
                return;
            } else {
                session.result = GameResultState.Loss;
            }
        } else if (selectedPath == 1) { // Medium path - combat
            // actionValue is combat style (0-2)
            uint256 enemyStyle = getRandomNumber(keccak256(abi.encodePacked(sessionId, "combat")), 3);
            // Rock-paper-scissors style combat
            if ((actionValue == 0 && enemyStyle == 2) ||
                (actionValue == 1 && enemyStyle == 0) ||
                (actionValue == 2 && enemyStyle == 1)) {
                // Win, move to next stage
                return;
            } else {
                session.result = GameResultState.Loss;
            }
        } else if (selectedPath == 2) { // Hard path - treasure hunt
            // actionValue is treasure location (0-9)
            uint256 correctLocation = getRandomNumber(keccak256(abi.encodePacked(sessionId, "treasure")), 10);
            if (actionValue == correctLocation) {
                // Found the treasure, move to next stage
                return;
            } else {
                session.result = GameResultState.Loss;
            }
        }
    } else if (currentStage == 2) {
        // Final quest stage - boss battle
        uint256 selectedPath = session.gameSpecificData;
        uint256 bossHealth = 50 + (selectedPath * 25); // Higher difficulty paths have stronger bosses
        uint256 playerDamage = 10 + (actionValue % 20);
        
        // Check if player damage is enough to defeat boss
        if (playerDamage >= bossHealth) {
            // Victory!
            session.result = GameResultState.Win;
            
            // Reward adjustment based on path difficulty
            if (selectedPath == 1) { // Medium path
                session.potentialReward = session.potentialReward.mul(125).div(100); // 25% bonus
            } else if (selectedPath == 2) { // Hard path
                session.potentialReward = session.potentialReward.mul(150).div(100); // 50% bonus
            }
            
            updateLeaderboard(uint256(GameType.QuestChallenge), session.player, session.potentialReward);
        } else {
            session.result = GameResultState.Loss;
        }
    }
    
    // If game ended, emit result
    if (session.result != GameResultState.Pending) {
        recordGamePlayed(session.player, uint256(session.gameType), 
            session.result == GameResultState.Win, 
            session.moveHistory.length);
        
        emit GameResult(
            sessionId, 
            session.player, 
            session.result, 
            session.result == GameResultState.Win ? session.potentialReward : 0
        );
    }
}

// Update leaderboard for a game
function updateLeaderboard(uint256 gameType, address player, uint256 score) internal {
    LeaderboardEntry[] storage leaderboard = gameLeaderboards[gameType];
    
    // Check if player is already on leaderboard with a better score
    bool found = false;
    for (uint256 i = 0; i < leaderboard.length; i++) {
        if (leaderboard[i].player == player) {
            if (score > leaderboard[i].score) {
                leaderboard[i].score = score;
                leaderboard[i].timestamp = block.timestamp;
            }
            found = true;
            break;
        }
    }
    
    // If not found and leaderboard not full, add new entry
    if (!found && leaderboard.length < maxLeaderboardEntries) {
        leaderboard.push(LeaderboardEntry({
            player: player,
            score: score,
            timestamp: block.timestamp
        }));
    } 
    // If not found and leaderboard full, check if score is higher than lowest score
    else if (!found) {
        // Find lowest score
        uint256 lowestIndex = 0;
        uint256 lowestScore = leaderboard[0].score;
        
        for (uint256 i = 1; i < leaderboard.length; i++) {
            if (leaderboard[i].score < lowestScore) {
                lowestScore = leaderboard[i].score;
                lowestIndex = i;
            }
        }
        
        // Replace if new score is higher
        if (score > lowestScore) {
            leaderboard[lowestIndex] = LeaderboardEntry({
                player: player,
                score: score,
                timestamp: block.timestamp
            });
        }
    }
    
    // Sort leaderboard (simple bubble sort)
    for (uint256 i = 0; i < leaderboard.length - 1; i++) {
        for (uint256 j = 0; j < leaderboard.length - i - 1; j++) {
            if (leaderboard[j].score < leaderboard[j + 1].score) {
                LeaderboardEntry memory temp = leaderboard[j];
                leaderboard[j] = leaderboard[j + 1];
                leaderboard[j + 1] = temp;
            }
        }
    }
    
    emit LeaderboardUpdated(gameType, player, score);
}

// Getter function for leaderboard
function getLeaderboard(uint256 gameType) external view returns (address[] memory, uint256[] memory, uint256[] memory) {
    LeaderboardEntry[] storage leaderboard = gameLeaderboards[gameType];
    
    address[] memory players = new address[](leaderboard.length);
    uint256[] memory scores = new uint256[](leaderboard.length);
    uint256[] memory timestamps = new uint256[](leaderboard.length);
    
    for (uint256 i = 0; i < leaderboard.length; i++) {
        players[i] = leaderboard[i].player;
        scores[i] = leaderboard[i].score;
        timestamps[i] = leaderboard[i].timestamp;
    }
    
    return (players, scores, timestamps);
}

// Getter function for game session details
function getGameSession(bytes32 sessionId) external view returns (
    uint256 gameId,
    GameType gameType,
    address player,
    uint256 betAmount,
    uint256 potentialReward,
    uint256 timestamp,
    GameResultState result,
    bool rewardClaimed,
    uint256 gameSpecificData,
    uint256[] memory moveHistory
) {
    GameSession storage session = gameSessions[sessionId];
    
    return (
        session.gameId,
        session.gameType,
        session.player,
        session.betAmount,
        session.potentialReward,
        session.timestamp,
        session.result,
        session.rewardClaimed,
        session.gameSpecificData,
        session.moveHistory
    );
}

// Admin function to set minimum bet for game type
function setGameTypeMinimumBet(uint256 gameTypeId, uint256 minimumBet) external onlyOwner {
    gameTypeMinimumBet[gameTypeId] = minimumBet;
}

// Admin function to set payout multiplier for game type
function setGameTypePayout(uint256 gameTypeId, uint256 payoutMultiplier) external onlyOwner {
    gameTypePayout[gameTypeId] = payoutMultiplier;
}

// Admin function to set max number of leaderboard entries
function setMaxLeaderboardEntries(uint256 maxEntries) external onlyOwner {
    require(maxEntries > 0 && maxEntries <= 100, "Invalid max entries");
    maxLeaderboardEntries = maxEntries;
}

// ======================= NFT SYSTEM =======================
// NFT Collection Structure
struct NFTCollection {
    string name;
    string description;
    uint256 totalSupply;
    uint256 mintedCount;
    uint256 minPrice;
    bool isLimited;
    bool isActive;
    address creator;
    uint256 royaltyPercentage;
    mapping(uint256 => bool) existingTokenIds;
    mapping(uint256 => NFTAttributes) tokenAttributes;
}

// NFT Attributes Structure
struct NFTAttributes {
    string name;
    uint256 rarity;
    uint256 power;
    uint256 level;
    uint256 experience;
    bool isEquipped;
    uint256[] traits;
    uint256 creationTime;
    uint256 lastTransferTime;
    uint256 upgradeCount;
}

// NFT Market Listing Structure
struct NFTMarketListing {
    address seller;
    uint256 collectionId;
    uint256 tokenId;
    uint256 price;
    uint256 listingTime;
    bool isActive;
}

// NFT Auction Structure
struct NFTAuction {
    address seller;
    uint256 collectionId;
    uint256 tokenId;
    uint256 startingPrice;
    uint256 currentBid;
    address currentBidder;
    uint256 startTime;
    uint256 endTime;
    bool isActive;
    bool isSettled;
}

// Mappings for NFT data
mapping(uint256 => NFTCollection) public nftCollections;
mapping(uint256 => string) public collectionURIPrefix;
mapping(uint256 => mapping(uint256 => address)) public nftOwners;
mapping(address => mapping(uint256 => uint256[])) public ownedNFTs;
mapping(bytes32 => NFTMarketListing) public marketListings;
mapping(bytes32 => NFTAuction) public nftAuctions;
mapping(address => bytes32[]) public userListings;
mapping(address => bytes32[]) public userAuctions;
mapping(address => bytes32[]) public userBids;

// Counters
uint256 public nftCollectionCount;
uint256 public totalNFTsMinted;
uint256 public activeListingsCount;
uint256 public activeAuctionsCount;

// Events
event NFTCollectionCreated(uint256 indexed collectionId, string name, address creator);
event NFTMinted(uint256 indexed collectionId, uint256 indexed tokenId, address indexed owner);
event NFTTransferred(uint256 indexed collectionId, uint256 indexed tokenId, address indexed from, address to);
event NFTListed(bytes32 indexed listingId, uint256 collectionId, uint256 tokenId, address seller, uint256 price);
event NFTUnlisted(bytes32 indexed listingId);
event NFTPurchased(bytes32 indexed listingId, address buyer, uint256 price);
event NFTAuctionCreated(bytes32 indexed auctionId, uint256 collectionId, uint256 tokenId, address seller);
event NFTAuctionBid(bytes32 indexed auctionId, address bidder, uint256 bidAmount);
event NFTAuctionSettled(bytes32 indexed auctionId, address winner, uint256 finalPrice);
event NFTAuctionCancelled(bytes32 indexed auctionId);
event NFTAttributesUpdated(uint256 indexed collectionId, uint256 indexed tokenId);

// NFT Collection Management
function createNFTCollection(
    string memory name,
    string memory description,
    string memory uriPrefix,
    uint256 totalSupply,
    uint256 minPrice,
    uint256 royaltyPercentage,
    bool isLimited
) external nonReentrant returns (uint256) {
    require(bytes(name).length > 0, "Name cannot be empty");
    require(royaltyPercentage <= 1000, "Royalty too high"); // Max 10%
    
    uint256 collectionId = nftCollectionCount++;
    
    NFTCollection storage collection = nftCollections[collectionId];
    collection.name = name;
    collection.description = description;
    collection.totalSupply = isLimited ? totalSupply : type(uint256).max;
    collection.mintedCount = 0;
    collection.minPrice = minPrice;
    collection.isLimited = isLimited;
    collection.isActive = true;
    collection.creator = msg.sender;
    collection.royaltyPercentage = royaltyPercentage;
    
    collectionURIPrefix[collectionId] = uriPrefix;
    
    emit NFTCollectionCreated(collectionId, name, msg.sender);
    
    return collectionId;
}

function updateCollectionStatus(uint256 collectionId, bool isActive) external {
    require(nftCollections[collectionId].creator == msg.sender || owner() == msg.sender, "Not authorized");
    nftCollections[collectionId].isActive = isActive;
}

function mintNFT(
    uint256 collectionId,
    uint256 tokenId,
    string memory name,
    uint256 rarity,
    uint256 power,
    uint256[] memory traits
) external payable nonReentrant returns (uint256) {
    NFTCollection storage collection = nftCollections[collectionId];
    
    require(collection.isActive, "Collection not active");
    require(collection.mintedCount < collection.totalSupply, "Collection supply limit reached");
    require(!collection.existingTokenIds[tokenId], "Token ID already exists");
    require(msg.value >= collection.minPrice, "Insufficient payment");
    
    // Handle payment
    uint256 creatorFee = msg.value.mul(65).div(100); // 65% to creator
    uint256 platformFee = msg.value.sub(creatorFee); // 35% to platform
    
    payable(collection.creator).transfer(creatorFee);
    treasuryBalance = treasuryBalance.add(platformFee);
    
    // Mint NFT
    collection.existingTokenIds[tokenId] = true;
    collection.mintedCount++;
    
    // Set attributes
    NFTAttributes storage attrs = collection.tokenAttributes[tokenId];
    attrs.name = name;
    attrs.rarity = rarity;
    attrs.power = power;
    attrs.level = 1;
    attrs.experience = 0;
    attrs.isEquipped = false;
    attrs.traits = traits;
    attrs.creationTime = block.timestamp;
    attrs.lastTransferTime = block.timestamp;
    attrs.upgradeCount = 0;
    
    // Assign ownership
    nftOwners[collectionId][tokenId] = msg.sender;
    ownedNFTs[msg.sender][collectionId].push(tokenId);
    
    totalNFTsMinted++;
    
    emit NFTMinted(collectionId, tokenId, msg.sender);
    
    return tokenId;
}

// NFT Transfer Function
function transferNFT(uint256 collectionId, uint256 tokenId, address to) external nonReentrant {
    require(to != address(0), "Cannot transfer to zero address");
    require(nftOwners[collectionId][tokenId] == msg.sender, "Not the owner");
    
    // Remove from current owner's list
    uint256[] storage ownerNFTs = ownedNFTs[msg.sender][collectionId];
    for (uint256 i = 0; i < ownerNFTs.length; i++) {
        if (ownerNFTs[i] == tokenId) {
            ownerNFTs[i] = ownerNFTs[ownerNFTs.length - 1];
            ownerNFTs.pop();
            break;
        }
    }
    
    // Add to recipient's list
    ownedNFTs[to][collectionId].push(tokenId);
    
    // Update ownership
    nftOwners[collectionId][tokenId] = to;
    
    // Update last transfer time
    nftCollections[collectionId].tokenAttributes[tokenId].lastTransferTime = block.timestamp;
    
    emit NFTTransferred(collectionId, tokenId, msg.sender, to);
}

// NFT Marketplace Functions
function listNFTForSale(uint256 collectionId, uint256 tokenId, uint256 price) external nonReentrant returns (bytes32) {
    require(nftOwners[collectionId][tokenId] == msg.sender, "Not the owner");
    require(price > 0, "Price must be greater than zero");
    
    // Generate listing ID
    bytes32 listingId = keccak256(abi.encodePacked(
        collectionId,
        tokenId,
        msg.sender,
        block.timestamp,
        nonce++
    ));
    
    // Create listing
    marketListings[listingId] = NFTMarketListing({
        seller: msg.sender,
        collectionId: collectionId,
        tokenId: tokenId,
        price: price,
        listingTime: block.timestamp,
        isActive: true
    });
    
    // Add to user's listings
    userListings[msg.sender].push(listingId);
    
    activeListingsCount++;
    
    emit NFTListed(listingId, collectionId, tokenId, msg.sender, price);
    
    return listingId;
}

function cancelNFTListing(bytes32 listingId) external nonReentrant {
    NFTMarketListing storage listing = marketListings[listingId];
    
    require(listing.seller == msg.sender, "Not the seller");
    require(listing.isActive, "Listing not active");
    
    listing.isActive = false;
    
    activeListingsCount--;
    
    emit NFTUnlisted(listingId);
}

function buyNFT(bytes32 listingId) external payable nonReentrant {
    NFTMarketListing storage listing = marketListings[listingId];
    
    require(listing.isActive, "Listing not active");
    require(msg.value >= listing.price, "Insufficient payment");
    require(nftOwners[listing.collectionId][listing.tokenId] == listing.seller, "Seller no longer owns NFT");
    
    // Calculate fees
    uint256 marketplaceFee = listing.price.mul(nftMarketplaceFee).div(FEE_DENOMINATOR);
    uint256 royaltyFee = listing.price.mul(nftCollections[listing.collectionId].royaltyPercentage).div(FEE_DENOMINATOR);
    uint256 sellerProceeds = listing.price.sub(marketplaceFee).sub(royaltyFee);
    
    // Transfer funds
    treasuryBalance = treasuryBalance.add(marketplaceFee);
    payable(nftCollections[listing.collectionId].creator).transfer(royaltyFee);
    payable(listing.seller).transfer(sellerProceeds);
    
    // Refund excess payment
    if (msg.value > listing.price) {
        payable(msg.sender).transfer(msg.value.sub(listing.price));
    }
    
    // Transfer NFT
    uint256[] storage sellerNFTs = ownedNFTs[listing.seller][listing.collectionId];
    for (uint256 i = 0; i < sellerNFTs.length; i++) {
        if (sellerNFTs[i] == listing.tokenId) {
            sellerNFTs[i] = sellerNFTs[sellerNFTs.length - 1];
            sellerNFTs.pop();
            break;
        }
    }
    
    ownedNFTs[msg.sender][listing.collectionId].push(listing.tokenId);
    nftOwners[listing.collectionId][listing.tokenId] = msg.sender;
    
    // Update listing
    listing.isActive = false;
    activeListingsCount--;
    
    // Update last transfer time
    nftCollections[listing.collectionId].tokenAttributes[listing.tokenId].lastTransferTime = block.timestamp;
    
    emit NFTPurchased(listingId, msg.sender, listing.price);
    emit NFTTransferred(listing.collectionId, listing.tokenId, listing.seller, msg.sender);
}

// NFT Auction Functions
function createNFTAuction(
    uint256 collectionId,
    uint256 tokenId,
    uint256 startingPrice,
    uint256 duration
) external nonReentrant returns (bytes32) {
    require(nftOwners[collectionId][tokenId] == msg.sender, "Not the owner");
    require(startingPrice > 0, "Starting price must be greater than zero");
    require(duration >= 1 hours && duration <= 7 days, "Invalid duration");
    
    // Generate auction ID
    bytes32 auctionId = keccak256(abi.encodePacked(
        collectionId,
        tokenId,
        msg.sender,
        block.timestamp,
        nonce++
    ));
    
    // Create auction
    nftAuctions[auctionId] = NFTAuction({
        seller: msg.sender,
        collectionId: collectionId,
        tokenId: tokenId,
        startingPrice: startingPrice,
        currentBid: 0,
        currentBidder: address(0),
        startTime: block.timestamp,
        endTime: block.timestamp + duration,
        isActive: true,
        isSettled: false
    });
    
    // Add to user's auctions
    userAuctions[msg.sender].push(auctionId);
    
    activeAuctionsCount++;
    
    emit NFTAuctionCreated(auctionId, collectionId, tokenId, msg.sender);
    
    return auctionId;
}

function placeBid(bytes32 auctionId) external payable nonReentrant {
    NFTAuction storage auction = nftAuctions[auctionId];
    
    require(auction.isActive, "Auction not active");
    require(block.timestamp < auction.endTime, "Auction ended");
    require(auction.seller != msg.sender, "Seller cannot bid");
    
    uint256 minBid;
    if (auction.currentBid == 0) {
        minBid = auction.startingPrice;
    } else {
        minBid = auction.currentBid.mul(105).div(100); // Minimum 5% increase
    }
    
    require(msg.value >= minBid, "Bid too low");
    
    // Refund previous bidder
    if (auction.currentBidder != address(0)) {
        payable(auction.currentBidder).transfer(auction.currentBid);
    }
    
    // Update auction
    auction.currentBid = msg.value;
    auction.currentBidder = msg.sender;
    
    // Add to user's bids
    userBids[msg.sender].push(auctionId);
    
    // Extend auction if bid is placed near the end
    if (auction.endTime - block.timestamp < 10 minutes) {
        auction.endTime += 10 minutes;
    }
    
    emit NFTAuctionBid(auctionId, msg.sender, msg.value);
}

function settleAuction(bytes32 auctionId) external nonReentrant {
    NFTAuction storage auction = nftAuctions[auctionId];
    
    require(auction.isActive, "Auction not active");
    require(!auction.isSettled, "Auction already settled");
    require(block.timestamp >= auction.endTime, "Auction not ended");
    
    // Mark as settled
    auction.isActive = false;
    auction.isSettled = true;
    
    activeAuctionsCount--;
    
    // If there were no bids, return NFT to seller
    if (auction.currentBidder == address(0)) {
        emit NFTAuctionCancelled(auctionId);
        return;
    }
    
    // Calculate fees
    uint256 marketplaceFee = auction.currentBid.mul(nftMarketplaceFee).div(FEE_DENOMINATOR);
    uint256 royaltyFee = auction.currentBid.mul(nftCollections[auction.collectionId].royaltyPercentage).div(FEE_DENOMINATOR);
    uint256 sellerProceeds = auction.currentBid.sub(marketplaceFee).sub(royaltyFee);
    
    // Transfer funds
    treasuryBalance = treasuryBalance.add(marketplaceFee);
    payable(nftCollections[auction.collectionId].creator).transfer(royaltyFee);
    payable(auction.seller).transfer(sellerProceeds);
    
    // Transfer NFT
    uint256[] storage sellerNFTs = ownedNFTs[auction.seller][auction.collectionId];
    for (uint256 i = 0; i < sellerNFTs.length; i++) {
        if (sellerNFTs[i] == auction.tokenId) {
            sellerNFTs[i] = sellerNFTs[sellerNFTs.length - 1];
            sellerNFTs.pop();
            break;
        }
    }
    
    ownedNFTs[auction.currentBidder][auction.collectionId].push(auction.tokenId);
    nftOwners[auction.collectionId][auction.tokenId] = auction.currentBidder;
    
    // Update last transfer time
    nftCollections[auction.collectionId].tokenAttributes[auction.tokenId].lastTransferTime = block.timestamp;
    
    emit NFTAuctionSettled(auctionId, auction.currentBidder, auction.currentBid);
    emit NFTTransferred(auction.collectionId, auction.tokenId, auction.seller, auction.currentBidder);
}

function cancelAuction(bytes32 auctionId) external nonReentrant {
    NFTAuction storage auction = nftAuctions[auctionId];
    
    require(auction.seller == msg.sender, "Not the seller");
    require(auction.isActive, "Auction not active");
    require(auction.currentBidder == address(0), "Cannot cancel with active bids");
    
    auction.isActive = false;
    auction.isSettled = true;
    
    activeAuctionsCount--;
    
    emit NFTAuctionCancelled(auctionId);
}

// NFT Integration with Game System
function useNFTInGame(uint256 collectionId, uint256 tokenId, uint256 gameId) external nonReentrant {
    require(nftOwners[collectionId][tokenId] == msg.sender, "Not the owner");
    require(gameStatus[gameId] == GameStatus.Active, "Game not active");
    
    NFTAttributes storage attrs = nftCollections[collectionId].tokenAttributes[tokenId];
    
    // Add XP to NFT
    attrs.experience += 10;
    
    // Check for level up
    if (attrs.experience >= attrs.level * 100) {
        attrs.level++;
        attrs.power += 5;
    }
    
    emit NFTAttributesUpdated(collectionId, tokenId);
}

function upgradeNFT(uint256 collectionId, uint256 tokenId) external payable nonReentrant {
    require(nftOwners[collectionId][tokenId] == msg.sender, "Not the owner");
    
    NFTAttributes storage attrs = nftCollections[collectionId].tokenAttributes[tokenId];
    
    // Calculate upgrade cost
    uint256 upgradeCost = attrs.level.mul(attrs.upgradeCount + 1).mul(0.01 ether);
    require(msg.value >= upgradeCost, "Insufficient payment");
    
    // Apply upgrade
    attrs.power += 10;
    attrs.upgradeCount++;
    
    // Add to treasury
    treasuryBalance = treasuryBalance.add(msg.value);
    
    // Refund excess payment
    if (msg.value > upgradeCost) {
        payable(msg.sender).transfer(msg.value.sub(upgradeCost));
    }
    
    emit NFTAttributesUpdated(collectionId, tokenId);
}

function getNFTAttributes(uint256 collectionId, uint256 tokenId) external view returns (
    string memory name,
    uint256 rarity,
    uint256 power,
    uint256 level,
    uint256 experience,
    bool isEquipped,
    uint256[] memory traits,
    uint256 creationTime,
    uint256 lastTransferTime,
    uint256 upgradeCount
) {
    NFTAttributes storage attrs = nftCollections[collectionId].tokenAttributes[tokenId];
    
    return (
        attrs.name,
        attrs.rarity,
        attrs.power,
        attrs.level,
        attrs.experience,
        attrs.isEquipped,
        attrs.traits,
        attrs.creationTime,
        attrs.lastTransferTime,
        attrs.upgradeCount
    );
}

function getNFTsOwnedByUser(address user, uint256 collectionId) external view returns (uint256[] memory) {
    return ownedNFTs[user][collectionId];
}

// ======================= MULTIVERSE TOURNAMENT SYSTEM =======================
// Tournament Structure
struct Tournament {
    string name;
    uint256 gameType;
    uint256 entryFee;
    uint256 prizePool;
    uint256 maxParticipants;
    uint256 startTime;
    uint256 endTime;
    address[] participants;
    mapping(address => uint256) scores;
    address[] winners;
    uint256[] prizes;
    bool isActive;
    bool isFinalized;
}

// Tournament Mappings
mapping(uint256 => Tournament) public tournaments;
uint256 public tournamentCount;
mapping(address => uint256[]) public userTournaments;

// Tournament Events
event TournamentCreated(uint256 indexed tournamentId, string name, uint256 gameType);
event TournamentJoined(uint256 indexed tournamentId, address participant);
event TournamentScoreUpdated(uint256 indexed tournamentId, address participant, uint256 score);
event TournamentFinalized(uint256 indexed tournamentId, address[] winners, uint256[] prizes);

// Create a tournament
function createTournament(
    string memory name,
    uint256 gameType,
    uint256 entryFee,
    uint256 maxParticipants,
    uint256 duration
) external onlyOwner returns (uint256) {
    require(bytes(name).length > 0, "Name cannot be empty");
    require(gameStatus[gameType] == GameStatus.Active, "Game not active");
    require(maxParticipants > 1, "Need at least 2 participants");
    
    uint256 tournamentId = tournamentCount++;
    
    Tournament storage tournament = tournaments[tournamentId];
    tournament.name = name;
    tournament.gameType = gameType;
    tournament.entryFee = entryFee;
    tournament.prizePool = 0;
    tournament.maxParticipants = maxParticipants;
    tournament.startTime = block.timestamp;
    tournament.endTime = block.timestamp + duration;
    tournament.isActive = true;
    tournament.isFinalized = false;
    
    emit TournamentCreated(tournamentId, name, gameType);
    
    return tournamentId;
}

// Join a tournament
function joinTournament(uint256 tournamentId) external payable nonReentrant {
    Tournament storage tournament = tournaments[tournamentId];
    
    require(tournament.isActive, "Tournament not active");
    require(block.timestamp < tournament.endTime, "Tournament has ended");
    require(tournament.participants.length < tournament.maxParticipants, "Tournament full");
    require(msg.value >= tournament.entryFee, "Insufficient entry fee");
    
    // Check if already joined
    for (uint256 i = 0; i < tournament.participants.length; i++) {
        require(tournament.participants[i] != msg.sender, "Already joined");
    }
    
    // Add to prize pool
    tournament.prizePool = tournament.prizePool.add(tournament.entryFee);
    
    // Refund excess payment
    if (msg.value > tournament.entryFee) {
        payable(msg.sender).transfer(msg.value.sub(tournament.entryFee));
    }
    
    // Add participant
    tournament.participants.push(msg.sender);
    tournament.scores[msg.sender] = 0;
    
    // Add to user's tournaments
    userTournaments[msg.sender].push(tournamentId);
    
    emit TournamentJoined(tournamentId, msg.sender);
}
// Update tournament score
function updateTournamentScore(uint256 tournamentId, address participant, uint256 score) external onlyOwner {
    Tournament storage tournament = tournaments[tournamentId];
    
    require(tournament.isActive, "Tournament not active");
    require(block.timestamp < tournament.endTime, "Tournament has ended");
    
    // Check if participant is in tournament
    bool isParticipant = false;
    for (uint256 i = 0; i < tournament.participants.length; i++) {
        if (tournament.participants[i] == participant) {
            isParticipant = true;
            break;
        }
    }
    require(isParticipant, "Not a participant");
    
    // Update score
    tournament.scores[participant] = score;
    
    emit TournamentScoreUpdated(tournamentId, participant, score);
}

// Finalize tournament and distribute rewards
function finalizeTournament(uint256 tournamentId) external onlyOwner {
    Tournament storage tournament = tournaments[tournamentId];
    
    require(tournament.isActive, "Tournament not active");
    require(!tournament.isFinalized, "Tournament already finalized");
    require(block.timestamp >= tournament.endTime, "Tournament not ended");
    
    // Sort participants by score
    address[] memory sortedParticipants = tournament.participants;
    uint256[] memory scores = new uint256[](sortedParticipants.length);
    
    for (uint256 i = 0; i < sortedParticipants.length; i++) {
        scores[i] = tournament.scores[sortedParticipants[i]];
    }
    
    // Bubble sort (simple but inefficient - replace with more efficient sort for production)
    for (uint256 i = 0; i < sortedParticipants.length - 1; i++) {
        for (uint256 j = 0; j < sortedParticipants.length - i - 1; j++) {
            if (scores[j] < scores[j + 1]) {
                // Swap scores
                uint256 tempScore = scores[j];
                scores[j] = scores[j + 1];
                scores[j + 1] = tempScore;
                
                // Swap participants
                address tempParticipant = sortedParticipants[j];
                sortedParticipants[j] = sortedParticipants[j + 1];
                sortedParticipants[j + 1] = tempParticipant;
            }
        }
    }
    
    // Determine winners and prizes
    uint256 numWinners = sortedParticipants.length > 3 ? 3 : sortedParticipants.length;
    address[] memory winners = new address[](numWinners);
    uint256[] memory prizes = new uint256[](numWinners);
    
    // Prize distribution: 1st: 50%, 2nd: 30%, 3rd: 20%
    if (numWinners >= 1) {
        winners[0] = sortedParticipants[0];
        prizes[0] = tournament.prizePool * 50 / 100;
    }
    
    if (numWinners >= 2) {
        winners[1] = sortedParticipants[1];
        prizes[1] = tournament.prizePool * 30 / 100;
    }
    
    if (numWinners >= 3) {
        winners[2] = sortedParticipants[2];
        prizes[2] = tournament.prizePool * 20 / 100;
    }
    
    // Save winners and prizes
    tournament.winners = winners;
    tournament.prizes = prizes;
    
    // Distribute prizes
    for (uint256 i = 0; i < numWinners; i++) {
        payable(winners[i]).transfer(prizes[i]);
    }
    
    // Update tournament status
    tournament.isActive = false;
    tournament.isFinalized = true;
    
    emit TournamentFinalized(tournamentId, winners, prizes);
}

// Get tournament details
function getTournamentDetails(uint256 tournamentId) external view returns (
    string memory name,
    uint256 gameType,
    uint256 entryFee,
    uint256 prizePool,
    uint256 maxParticipants,
    uint256 startTime,
    uint256 endTime,
    uint256 participantCount,
    bool isActive,
    bool isFinalized
) {
    Tournament storage tournament = tournaments[tournamentId];
    
    return (
        tournament.name,
        tournament.gameType,
        tournament.entryFee,
        tournament.prizePool,
        tournament.maxParticipants,
        tournament.startTime,
        tournament.endTime,
        tournament.participants.length,
        tournament.isActive,
        tournament.isFinalized
    );
}

// Get tournament participants
function getTournamentParticipants(uint256 tournamentId) external view returns (address[] memory) {
    return tournaments[tournamentId].participants;
}

// Get participant score
function getParticipantScore(uint256 tournamentId, address participant) external view returns (uint256) {
    return tournaments[tournamentId].scores[participant];
}

// Get tournament winners
function getTournamentWinners(uint256 tournamentId) external view returns (address[] memory, uint256[] memory) {
    Tournament storage tournament = tournaments[tournamentId];
    require(tournament.isFinalized, "Tournament not finalized");
    
    return (tournament.winners, tournament.prizes);
}

// ======================= QUESTS AND ACHIEVEMENTS SYSTEM =======================

struct Quest {
    string name;
    string description;
    uint256 difficultyLevel;
    uint256 experienceReward;
    uint256 tokenReward;
    uint256 completionTime;
    bool isActive;
    mapping(address => bool) completed;
    mapping(address => uint256) progress;
}

mapping(uint256 => Quest) public quests;
uint256 public questCount;

event QuestCreated(uint256 indexed questId, string name, uint256 difficultyLevel);
event QuestProgressUpdated(uint256 indexed questId, address indexed player, uint256 progress);
event QuestCompleted(uint256 indexed questId, address indexed player, uint256 experienceReward, uint256 tokenReward);

// Create a new quest
function createQuest(
    string memory name,
    string memory description,
    uint256 difficultyLevel,
    uint256 experienceReward,
    uint256 tokenReward,
    uint256 completionTime
) external onlyOwner returns (uint256) {
    require(bytes(name).length > 0, "Name cannot be empty");
    require(difficultyLevel >= 1 && difficultyLevel <= 5, "Difficulty must be between 1 and 5");
    
    uint256 questId = questCount++;
    
    Quest storage quest = quests[questId];
    quest.name = name;
    quest.description = description;
    quest.difficultyLevel = difficultyLevel;
    quest.experienceReward = experienceReward;
    quest.tokenReward = tokenReward;
    quest.completionTime = completionTime;
    quest.isActive = true;
    
    emit QuestCreated(questId, name, difficultyLevel);
    
    return questId;
}

// Update quest progress
function updateQuestProgress(uint256 questId, address player, uint256 progress) external {
    require(msg.sender == owner() || msg.sender == address(this), "Not authorized");
    require(quests[questId].isActive, "Quest not active");
    require(!quests[questId].completed[player], "Quest already completed");
    
    quests[questId].progress[player] = progress;
    
    // Check if quest is completed
    if (progress >= 100) {
        completeQuest(questId, player);
    } else {
        emit QuestProgressUpdated(questId, player, progress);
    }
}

// Complete a quest
function completeQuest(uint256 questId, address player) internal {
    Quest storage quest = quests[questId];
    
    require(quest.isActive, "Quest not active");
    require(!quest.completed[player], "Quest already completed");
    
    // Mark as completed
    quest.completed[player] = true;
    
    // Award experience
    addExperience(player, quest.experienceReward);
    
    // Award tokens
    _mint(player, quest.tokenReward);
    
    emit QuestCompleted(questId, player, quest.experienceReward, quest.tokenReward);
}

// Get quest details
function getQuestDetails(uint256 questId) external view returns (
    string memory name,
    string memory description,
    uint256 difficultyLevel,
    uint256 experienceReward,
    uint256 tokenReward,
    uint256 completionTime,
    bool isActive
) {
    Quest storage quest = quests[questId];
    
    return (
        quest.name,
        quest.description,
        quest.difficultyLevel,
        quest.experienceReward,
        quest.tokenReward,
        quest.completionTime,
        quest.isActive
    );
}

// Check if player has completed a quest
function hasCompletedQuest(uint256 questId, address player) external view returns (bool) {
    return quests[questId].completed[player];
}

// Get player's quest progress
function getQuestProgress(uint256 questId, address player) external view returns (uint256) {
    return quests[questId].progress[player];
}

// ======================= CLAN SYSTEM =======================

struct Clan {
    string name;
    string description;
    address leader;
    uint256 creationTime;
    uint256 memberCount;
    uint256 totalExperience;
    uint256 level;
    bool isActive;
    mapping(address => bool) members;
    mapping(address => uint256) contributions;
}

mapping(uint256 => Clan) public clans;
mapping(address => uint256) public playerClan;
uint256 public clanCount;

event ClanCreated(uint256 indexed clanId, string name, address leader);
event ClanMemberAdded(uint256 indexed clanId, address member);
event ClanMemberRemoved(uint256 indexed clanId, address member);
event ClanContribution(uint256 indexed clanId, address member, uint256 amount);
event ClanLevelUp(uint256 indexed clanId, uint256 newLevel);

// Create a new clan
function createClan(string memory name, string memory description) external payable nonReentrant returns (uint256) {
    require(bytes(name).length > 0, "Name cannot be empty");
    require(playerClan[msg.sender] == 0, "Already in a clan");
    require(msg.value >= 0.1 ether, "Insufficient creation fee");
    
    uint256 clanId = clanCount + 1; // Start from 1, 0 means no clan
    clanCount = clanId;
    
    Clan storage clan = clans[clanId];
    clan.name = name;
    clan.description = description;
    clan.leader = msg.sender;
    clan.creationTime = block.timestamp;
    clan.memberCount = 1;
    clan.totalExperience = 0;
    clan.level = 1;
    clan.isActive = true;
    clan.members[msg.sender] = true;
    
    // Add player to clan
    playerClan[msg.sender] = clanId;
    
    // Add creation fee to treasury
    treasuryBalance = treasuryBalance.add(msg.value);
    
    emit ClanCreated(clanId, name, msg.sender);
    emit ClanMemberAdded(clanId, msg.sender);
    
    return clanId;
}

// Join a clan
function joinClan(uint256 clanId) external nonReentrant {
    require(clanId > 0 && clanId <= clanCount, "Clan does not exist");
    require(playerClan[msg.sender] == 0, "Already in a clan");
    require(clans[clanId].isActive, "Clan not active");
    require(!clans[clanId].members[msg.sender], "Already a member");
    
    // Add to clan
    clans[clanId].members[msg.sender] = true;
    clans[clanId].memberCount++;
    
    // Set player's clan
    playerClan[msg.sender] = clanId;
    
    emit ClanMemberAdded(clanId, msg.sender);
}

// Leave clan
function leaveClan() external nonReentrant {
    uint256 clanId = playerClan[msg.sender];
    require(clanId > 0, "Not in a clan");
    require(clans[clanId].leader != msg.sender, "Leader cannot leave, transfer leadership first");
    
    // Remove from clan
    clans[clanId].members[msg.sender] = false;
    clans[clanId].memberCount--;
    
    // Remove player's clan
    playerClan[msg.sender] = 0;
    
    emit ClanMemberRemoved(clanId, msg.sender);
}

// Contribute to clan
function contributeToClan(uint256 amount) external nonReentrant {
    uint256 clanId = playerClan[msg.sender];
    require(clanId > 0, "Not in a clan");
    require(amount > 0, "Amount must be greater than zero");
    require(balanceOf(msg.sender) >= amount, "Insufficient balance");
    
    // Transfer tokens to contract
    _transfer(msg.sender, address(this), amount);
    
    // Update clan contributions
    clans[clanId].contributions[msg.sender] += amount;
    
    // Update clan experience
    uint256 expGained = amount.div(10**16); // 1 exp per 0.01 tokens
    clans[clanId].totalExperience += expGained;
    
    // Check for level up
    uint256 expForNextLevel = clans[clanId].level * 1000;
    if (clans[clanId].totalExperience >= expForNextLevel) {
        clans[clanId].level++;
        emit ClanLevelUp(clanId, clans[clanId].level);
    }
    
    emit ClanContribution(clanId, msg.sender, amount);
}

// Transfer clan leadership
function transferClanLeadership(address newLeader) external nonReentrant {
    uint256 clanId = playerClan[msg.sender];
    require(clanId > 0, "Not in a clan");
    require(clans[clanId].leader == msg.sender, "Not the clan leader");
    require(clans[clanId].members[newLeader], "New leader must be a clan member");
    
    clans[clanId].leader = newLeader;
}

// Get clan details
function getClanDetails(uint256 clanId) external view returns (
    string memory name,
    string memory description,
    address leader,
    uint256 creationTime,
    uint256 memberCount,
    uint256 totalExperience,
    uint256 level,
    bool isActive
) {
    Clan storage clan = clans[clanId];
    
    return (
        clan.name,
        clan.description,
        clan.leader,
        clan.creationTime,
        clan.memberCount,
        clan.totalExperience,
        clan.level,
        clan.isActive
    );
}

// Check if address is clan member
function isClanMember(uint256 clanId, address member) external view returns (bool) {
    return clans[clanId].members[member];
}

// Get member contribution
function getClanContribution(uint256 clanId, address member) external view returns (uint256) {
    return clans[clanId].contributions[member];
}

// ======================= BATTLE PASS SYSTEM =======================

struct BattlePass {
    string name;
    uint256 season;
    uint256 startTime;
    uint256 endTime;
    uint256 maxLevel;
    uint256 premiumPrice;
    bool isActive;
}

struct BattlePassProgress {
    bool hasPremium;
    uint256 currentLevel;
    uint256 experience;
    mapping(uint256 => bool) claimedRewards;
    mapping(uint256 => bool) claimedPremiumRewards;
}

struct BattlePassReward {
    string name;
    uint256 tokenAmount;
    uint256 nftCollectionId;
    uint256 nftTokenId;
    bool isNFT;
}

mapping(uint256 => BattlePass) public battlePasses;
mapping(uint256 => mapping(uint256 => BattlePassReward)) public battlePassRewards;
mapping(uint256 => mapping(uint256 => BattlePassReward)) public battlePassPremiumRewards;
mapping(uint256 => mapping(address => BattlePassProgress)) public battlePassProgress;
uint256 public battlePassCount;

event BattlePassCreated(uint256 indexed battlePassId, string name, uint256 season);
event BattlePassPurchased(uint256 indexed battlePassId, address indexed player);
event BattlePassProgressUpdated(uint256 indexed battlePassId, address indexed player, uint256 level);
event BattlePassRewardClaimed(uint256 indexed battlePassId, address indexed player, uint256 level, bool isPremium);

// Create a battle pass
function createBattlePass(
    string memory name,
    uint256 season,
    uint256 duration,
    uint256 maxLevel,
    uint256 premiumPrice
) external onlyOwner returns (uint256) {
    require(bytes(name).length > 0, "Name cannot be empty");
    require(maxLevel > 0, "Max level must be greater than zero");
    
    uint256 battlePassId = battlePassCount++;
    
    BattlePass storage battlePass = battlePasses[battlePassId];
    battlePass.name = name;
    battlePass.season = season;
    battlePass.startTime = block.timestamp;
    battlePass.endTime = block.timestamp + duration;
    battlePass.maxLevel = maxLevel;
    battlePass.premiumPrice = premiumPrice;
    battlePass.isActive = true;
    
    emit BattlePassCreated(battlePassId, name, season);
    
    return battlePassId;
}

// Set battle pass reward
function setBattlePassReward(
    uint256 battlePassId,
    uint256 level,
    string memory name,
    uint256 tokenAmount,
    uint256 nftCollectionId,
    uint256 nftTokenId,
    bool isNFT,
    bool isPremium
) external onlyOwner {
    require(battlePassId < battlePassCount, "Battle pass does not exist");
    require(level > 0 && level <= battlePasses[battlePassId].maxLevel, "Invalid level");
    
    BattlePassReward memory reward = BattlePassReward({
        name: name,
        tokenAmount: tokenAmount,
        nftCollectionId: nftCollectionId,
        nftTokenId: nftTokenId,
        isNFT: isNFT
    });
    
    if (isPremium) {
        battlePassPremiumRewards[battlePassId][level] = reward;
    } else {
        battlePassRewards[battlePassId][level] = reward;
    }
}

// Purchase premium battle pass
function purchaseBattlePass(uint256 battlePassId) external payable nonReentrant {
    BattlePass storage battlePass = battlePasses[battlePassId];
    BattlePassProgress storage progress = battlePassProgress[battlePassId][msg.sender];
    
    require(battlePass.isActive, "Battle pass not active");
    require(block.timestamp < battlePass.endTime, "Battle pass has ended");
    require(!progress.hasPremium, "Already purchased");
    require(msg.value >= battlePass.premiumPrice, "Insufficient payment");
    
    // Set premium status
    progress.hasPremium = true;
    
    // Initialize progress if new
    if (progress.currentLevel == 0) {
        progress.currentLevel = 1;
        progress.experience = 0;
    }
    
    // Add to treasury
    treasuryBalance = treasuryBalance.add(msg.value);
    
    emit BattlePassPurchased(battlePassId, msg.sender);
}

// Add battle pass experience
function addBattlePassExperience(uint256 battlePassId, address player, uint256 experience) external {
    require(msg.sender == owner() || msg.sender == address(this), "Not authorized");
    require(battlePasses[battlePassId].isActive, "Battle pass not active");
    require(block.timestamp < battlePasses[battlePassId].endTime, "Battle pass has ended");
    
    BattlePassProgress storage progress = battlePassProgress[battlePassId][player];
    
    // Initialize progress if new
    if (progress.currentLevel == 0) {
        progress.currentLevel = 1;
        progress.experience = 0;
    }
    
    // Add experience
    progress.experience += experience;
    
    // Check for level up
    uint256 expForNextLevel = progress.currentLevel * 100;
    while (progress.experience >= expForNextLevel && progress.currentLevel < battlePasses[battlePassId].maxLevel) {
        progress.experience -= expForNextLevel;
        progress.currentLevel++;
        expForNextLevel = progress.currentLevel * 100;
        
        emit BattlePassProgressUpdated(battlePassId, player, progress.currentLevel);
    }
}

// Claim battle pass reward
function claimBattlePassReward(uint256 battlePassId, uint256 level, bool isPremium) external nonReentrant {
    BattlePass storage battlePass = battlePasses[battlePassId];
    BattlePassProgress storage progress = battlePassProgress[battlePassId][msg.sender];
    
    require(battlePass.isActive, "Battle pass not active");
    require(level <= progress.currentLevel, "Level not reached");
    
    if (isPremium) {
        require(progress.hasPremium, "Premium not purchased");
        require(!progress.claimedPremiumRewards[level], "Premium reward already claimed");
        
        progress.claimedPremiumRewards[level] = true;
        
        // Deliver premium reward
        BattlePassReward storage reward = battlePassPremiumRewards[battlePassId][level];
        if (reward.isNFT) {
            // Transfer NFT
            if (nftOwners[reward.nftCollectionId][reward.nftTokenId] == address(this)) {
                _transferNFTToPlayer(reward.nftCollectionId, reward.nftTokenId, msg.sender);
            }
        } else if (reward.tokenAmount > 0) {
            // Mint tokens
            _mint(msg.sender, reward.tokenAmount);
        }
    } else {
        require(!progress.claimedRewards[level], "Reward already claimed");
        
        progress.claimedRewards[level] = true;
        
        // Deliver free reward
        BattlePassReward storage reward = battlePassRewards[battlePassId][level];
        if (reward.isNFT) {
            // Transfer NFT
            if (nftOwners[reward.nftCollectionId][reward.nftTokenId] == address(this)) {
                _transferNFTToPlayer(reward.nftCollectionId, reward.nftTokenId, msg.sender);
            }
        } else if (reward.tokenAmount > 0) {
            // Mint tokens
            _mint(msg.sender, reward.tokenAmount);
        }
    }
    
    emit BattlePassRewardClaimed(battlePassId, msg.sender, level, isPremium);
}

// ฟังก์ชันภายในสำหรับการโอน NFT สำหรับรางวัลแบทเทิลพาส
function _transferNFTToPlayer(uint256 collectionId, uint256 tokenId, address to) internal {
    require(to != address(0), "Cannot transfer to zero address");
    require(nftOwners[collectionId][tokenId] == address(this), "Contract does not own this NFT");
    
    // ลบออกจากรายการ NFT ของเจ้าของปัจจุบัน
    uint256[] storage ownerNFTs = ownedNFTs[address(this)][collectionId];
    for (uint256 i = 0; i < ownerNFTs.length; i++) {
        if (ownerNFTs[i] == tokenId) {
            ownerNFTs[i] = ownerNFTs[ownerNFTs.length - 1];
            ownerNFTs.pop();
            break;
        }
    }
    
    // เพิ่มเข้าไปในรายการของผู้รับ
    ownedNFTs[to][collectionId].push(tokenId);
    
    // อัปเดตความเป็นเจ้าของ
    nftOwners[collectionId][tokenId] = to;
    
    // อัปเดตเวลาการโอนล่าสุด
    nftCollections[collectionId].tokenAttributes[tokenId].lastTransferTime = block.timestamp;
    
    emit NFTTransferred(collectionId, tokenId, address(this), to);
}

// Get battle pass details
function getBattlePassDetails(uint256 battlePassId) external view returns (
    string memory name,
    uint256 season,
    uint256 startTime,
    uint256 endTime,
    uint256 maxLevel,
    uint256 premiumPrice,
    bool isActive
) {
    BattlePass storage battlePass = battlePasses[battlePassId];
    
    return (
        battlePass.name,
        battlePass.season,
        battlePass.startTime,
        battlePass.endTime,
        battlePass.maxLevel,
        battlePass.premiumPrice,
        battlePass.isActive
    );
}

// Get battle pass progress
function getBattlePassProgress(uint256 battlePassId, address player) external view returns (
    bool hasPremium,
    uint256 currentLevel,
    uint256 experience
) {
    BattlePassProgress storage progress = battlePassProgress[battlePassId][player];
    
    return (
        progress.hasPremium,
        progress.currentLevel,
        progress.experience
    );
}

// Check if reward claimed
function isBattlePassRewardClaimed(uint256 battlePassId, address player, uint256 level, bool isPremium) external view returns (bool) {
    BattlePassProgress storage progress = battlePassProgress[battlePassId][player];
    
    if (isPremium) {
        return progress.claimedPremiumRewards[level];
    } else {
        return progress.claimedRewards[level];
    }
}

// ======================= GOVERNANCE SYSTEM =======================

struct Proposal {
    string title;
    string description;
    address proposer;
    uint256 startTime;
    uint256 endTime;
    uint256 forVotes;
    uint256 againstVotes;
    bool executed;
    bool passed;
    bytes callData;
    address targetContract;
}

mapping(uint256 => Proposal) public proposals;
mapping(uint256 => mapping(address => bool)) public hasVoted;
mapping(address => uint256) public votingPower;
uint256 public proposalCount;
uint256 public minimumVotingPower = 1000 * 10**18; // 1000 tokens to create proposal

event ProposalCreated(uint256 indexed proposalId, string title, address proposer);
event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 votes);
event ProposalExecuted(uint256 indexed proposalId, bool passed);

// Create a proposal
function createProposal(
    string memory title,
    string memory description,
    uint256 votingPeriod,
    bytes memory callData,
    address targetContract
) external nonReentrant returns (uint256) {
    require(bytes(title).length > 0, "Title cannot be empty");
    require(stakedAmount[msg.sender] >= minimumVotingPower, "Insufficient voting power");
    
    uint256 proposalId = proposalCount++;
    
    Proposal storage proposal = proposals[proposalId];
    proposal.title = title;
    proposal.description = description;
    proposal.proposer = msg.sender;
    proposal.startTime = block.timestamp;
    proposal.endTime = block.timestamp + votingPeriod;
    proposal.forVotes = 0;
    proposal.againstVotes = 0;
    proposal.executed = false;
    proposal.passed = false;
    proposal.callData = callData;
    proposal.targetContract = targetContract;
    
    emit ProposalCreated(proposalId, title, msg.sender);
    
    return proposalId;
}

// Cast vote on proposal
function castVote(uint256 proposalId, bool support) external nonReentrant {
    Proposal storage proposal = proposals[proposalId];
    
    require(block.timestamp >= proposal.startTime, "Voting not started");
    require(block.timestamp < proposal.endTime, "Voting ended");
    require(!hasVoted[proposalId][msg.sender], "Already voted");
    
    // Calculate voting power (based on staked tokens)
    uint256 votes = stakedAmount[msg.sender];
    require(votes > 0, "No voting power");
    
    // Record vote
    hasVoted[proposalId][msg.sender] = true;
    
    if (support) {
        proposal.forVotes += votes;
    } else {
        proposal.againstVotes += votes;
    }
    
    emit VoteCast(proposalId, msg.sender, support, votes);
}

// Execute proposal
function executeProposal(uint256 proposalId) external nonReentrant {
    Proposal storage proposal = proposals[proposalId];
    
    require(!proposal.executed, "Already executed");
    require(block.timestamp >= proposal.endTime, "Voting not ended");
    
    proposal.executed = true;
    
    // Check if proposal passed
    if (proposal.forVotes > proposal.againstVotes) {
        proposal.passed = true;
        
        // Execute call
        (bool success, ) = proposal.targetContract.call(proposal.callData);
        require(success, "Proposal execution failed");
    }
    
    emit ProposalExecuted(proposalId, proposal.passed);
}

// Get proposal details
function getProposalDetails(uint256 proposalId) external view returns (
    string memory title,
    string memory description,
    address proposer,
    uint256 startTime,
    uint256 endTime,
    uint256 forVotes,
    uint256 againstVotes,
    bool executed,
    bool passed
) {
    Proposal storage proposal = proposals[proposalId];
    
    return (
        proposal.title,
        proposal.description,
        proposal.proposer,
        proposal.startTime,
        proposal.endTime,
        proposal.forVotes,
        proposal.againstVotes,
        proposal.executed,
        proposal.passed
    );
}

// ======================= ANALYTICS SYSTEM =======================

// Global statistics
uint256 public totalTransactions;
uint256 public totalGamePlays;
uint256 public totalStakedTokens;
uint256 public totalNFTSales;
uint256 public totalUniquePlayers;
uint256 public totalRewardsPaid;

// User-level analytics
mapping(address => uint256) public userFirstActivityTime;
mapping(address => uint256) public userLastActivityTime;
mapping(address => uint256) public userTotalTransactions;
mapping(address => uint256) public userTotalStaked;
mapping(address => uint256) public userTotalGamePlays;
mapping(address => uint256) public userTotalRewardsEarned;

// Game analytics
mapping(uint256 => uint256) public gamePlayCount;
mapping(uint256 => uint256) public gameTotalBets;
mapping(uint256 => uint256) public gameTotalRewards;
mapping(uint256 => uint256) public gameHighestWin;

// Time-based analytics
mapping(uint256 => uint256) public dailyTransactions;
mapping(uint256 => uint256) public dailyNewUsers;
mapping(uint256 => uint256) public dailyStakedAmount;
mapping(uint256 => uint256) public dailyGamePlays;

// Track user activity
    function trackUserActivity(address user) internal {
        // First time activity
        if (userFirstActivityTime[user] == 0) {
            userFirstActivityTime[user] = block.timestamp;
            totalUniquePlayers++;
            
            // Track daily new users
            uint256 dayId = block.timestamp / 1 days;
            dailyNewUsers[dayId]++;
        }
        
        // Update last activity
        userLastActivityTime[user] = block.timestamp;
        
        // Update user transactions
        userTotalTransactions[user]++;
        totalTransactions++;
        
        // Track daily transactions
        uint256 dayId = block.timestamp / 1 days;
        dailyTransactions[dayId]++;
    }
    
    // Track game activity
    function trackGameActivity(address user, uint256 gameId, uint256 betAmount, uint256 rewardAmount) internal {
        // Update global stats
        totalGamePlays++;
        
        // Update game stats
        gamePlayCount[gameId]++;
        gameTotalBets[gameId] += betAmount;
        
        if (rewardAmount > 0) {
            gameTotalRewards[gameId] += rewardAmount;
            totalRewardsPaid += rewardAmount;
            userTotalRewardsEarned[user] += rewardAmount;
            
            if (rewardAmount > gameHighestWin[gameId]) {
                gameHighestWin[gameId] = rewardAmount;
            }
        }
        
        // Update user stats
        userTotalGamePlays[user]++;
        
        // Track daily game plays
        uint256 dayId = block.timestamp / 1 days;
        dailyGamePlays[dayId]++;
    }
    
    // Track staking activity
    function trackStakingActivity(address user, uint256 amount) internal {
        // Update global stats
        totalStakedTokens += amount;
        
        // Update user stats
        userTotalStaked[user] += amount;
        
        // Track daily staked amount
        uint256 dayId = block.timestamp / 1 days;
        dailyStakedAmount[dayId] += amount;
    }
    
    // Track NFT sales
    function trackNFTSale(uint256 saleAmount) internal {
        totalNFTSales++;
    }
    
    // Get user activity stats
    function getUserStats(address user) external view returns (
        uint256 firstActivity,
        uint256 lastActivity,
        uint256 totalTransactions,
        uint256 totalStaked,
        uint256 totalGamePlays,
        uint256 totalRewards
    ) {
        return (
            userFirstActivityTime[user],
            userLastActivityTime[user],
            userTotalTransactions[user],
            userTotalStaked[user],
            userTotalGamePlays[user],
            userTotalRewardsEarned[user]
        );
    }
    
    // Get daily stats
    function getDailyStats(uint256 dayId) external view returns (
        uint256 transactions,
        uint256 newUsers,
        uint256 stakedAmount,
        uint256 gamePlays
    ) {
        return (
            dailyTransactions[dayId],
            dailyNewUsers[dayId],
            dailyStakedAmount[dayId],
            dailyGamePlays[dayId]
        );
    }
    
    // Get game stats
    function getGameStats(uint256 gameId) external view returns (
        uint256 playCount,
        uint256 totalBets,
        uint256 totalRewards,
        uint256 highestWin
    ) {
        return (
            gamePlayCount[gameId],
            gameTotalBets[gameId],
            gameTotalRewards[gameId],
            gameHighestWin[gameId]
        );
    }
    
    // ======================= UTILITY FUNCTIONS =======================
    
    // Generate a unique ID
    function generateUniqueId(address user, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            user,
            block.timestamp,
            blockhash(block.number - 1),
            nonce
        ));
    }
    
    // Check if two strings are equal
    function stringsEqual(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
    
    // Convert address to string
    function addressToString(address _addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";
        
        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';
        
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        
        return string(str);
    }
    
    // Convert uint to string
    function uintToString(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        
        uint256 j = _i;
        uint256 length;
        
        while (j != 0) {
            length++;
            j /= 10;
        }
        
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        
        while (_i != 0) {
            k = k - 1;
            bstr[k] = bytes1(uint8(48 + _i % 10));
            _i /= 10;
        }
        
        return string(bstr);
    }
    
    // Calculate percentage
    function calculatePercentage(uint256 amount, uint256 percentage) internal pure returns (uint256) {
        return amount.mul(percentage).div(100);
    }
    
    // Random number between min and max
    function getRandomBetween(uint256 min, uint256 max, bytes32 seed) internal view returns (uint256) {
    require(max > min, "Max must be greater than min");
    
    uint256 randomNumber = uint256(keccak256(abi.encodePacked(
        seed,
        block.timestamp,
        blockhash(block.number - 1),
        msg.sender
    )));
    
    return min + (randomNumber % (max - min + 1));
}
    // ======================= EXTERNAL INTEGRATION FUNCTIONS =======================
    
    // Chainlink VRF integration (mock)
    function requestRandomness() external returns (bytes32 requestId) {
        requestId = keccak256(abi.encodePacked(
            msg.sender,
            block.timestamp,
            blockhash(block.number - 1),
            nonce++
        ));
        
        return requestId;
    }
    
    // Price feed integration (mock)
    function getLatestPrice() external view returns (int256) {
        // Mock price feed
        return int256(getRandomBetween(1000, 2000, keccak256(abi.encodePacked(block.timestamp))));
    }
    
    // External NFT integration
    function validateExternalNFT(address nftContract, uint256 tokenId) external view returns (bool) {
        // Mock validation
        return (nftContract != address(0) && tokenId > 0);
    }
    
    // Bridge to external chain (mock)
    function bridgeToExternalChain(address token, uint256 amount, uint256 chainId) external returns (bytes32) {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Amount must be greater than zero");
        
        bytes32 bridgeId = keccak256(abi.encodePacked(
            msg.sender,
            token,
            amount,
            chainId,
            block.timestamp,
            nonce++
        ));
        
        return bridgeId;
    }
    
    // ======================= ADVANCED MATHEMATICAL FUNCTIONS =======================
    
    // Bonding curve calculation
    function calculateBondingCurvePrice(uint256 supply, uint256 amount) internal pure returns (uint256) {
        // Simple bonding curve: price = (supply)^2
        uint256 startPrice = supply ** 2;
        uint256 endPrice = (supply + amount) ** 2;
        uint256 avgPrice = (startPrice + endPrice) / 2;
        
        return avgPrice * amount / 10**18;
    }
    
    // Calculate reward distribution using weighted allocation
    function calculateWeightedReward(uint256 totalReward, uint256[] memory weights) internal pure returns (uint256[] memory) {
        uint256[] memory rewards = new uint256[](weights.length);
        uint256 totalWeight = 0;
        
        // Calculate total weight
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }
        
        // Calculate rewards based on weights
        for (uint256 i = 0; i < weights.length; i++) {
            rewards[i] = totalReward * weights[i] / totalWeight;
        }
        
        return rewards;
    }
    
    // Exponential decay function for rewards
    function calculateExponentialDecay(uint256 initialValue, uint256 decayFactor, uint256 time) internal pure returns (uint256) {
        // decay = initialValue * (1 - decayFactor)^time
        uint256 factor = 100;
        for (uint256 i = 0; i < time; i++) {
            factor = factor * (100 - decayFactor) / 100;
        }
        
        return initialValue * factor / 100;
    }
    
    // Sigmoid function for smooth transitions
    function sigmoid(int256 x) internal pure returns (int256) {
        // Approximate sigmoid: 1 / (1 + e^-x)
        // We use a simplified version for on-chain calculations
        int256 PRECISION = 10000;
        
        if (x < -10 * PRECISION) return 0;
        if (x > 10 * PRECISION) return PRECISION;
        
        int256 e_x = PRECISION;
        if (x < 0) {
            x = -x;
            e_x = e_x * PRECISION / (e_x + x);
        } else {
            e_x = PRECISION * PRECISION / (PRECISION + PRECISION - x);
        }
        
        return PRECISION * PRECISION / (PRECISION + e_x);
    }
    
    // Logarithmic function for diminishing returns
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        
        while (value >= 10) {
            value /= 10;
            result += 1;
        }
        
        return result;
    }
    
    // Gaussian distribution function
    function gaussian(int256 x, int256 mean, int256 standardDeviation) internal pure returns (int256) {
        int256 PRECISION = 10000;
        
        // Simplified Gaussian calculation
        int256 exponent = -((x - mean) ** 2) / (2 * standardDeviation ** 2);
int256 factor = PRECISION / (standardDeviation * int256(31416) / 100); // sqrt(2*pi) ~= 2.5066        
        // Use the simplified sigmoid function as an approximation
        return factor * sigmoid(exponent);
    }
    
    // ======================= SECURITY FUNCTIONS =======================
    
    // Role-based access control
    mapping(address => mapping(bytes32 => bool)) private roles;
    
    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GAME_MANAGER_ROLE = keccak256("GAME_MANAGER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    
    // Grant role
    function grantRole(address account, bytes32 role) external onlyOwner {
        roles[account][role] = true;
    }
    
    // Revoke role
    function revokeRole(address account, bytes32 role) external onlyOwner {
        roles[account][role] = false;
    }
    
    // Check if has role
    function hasRole(address account, bytes32 role) public view returns (bool) {
        return roles[account][role];
    }
    
    // Role modifier
    modifier onlyRole(bytes32 role) {
        require(hasRole(msg.sender, role), "Does not have required role");
        _;
    }
    
    // Whitelist/blacklist
    mapping(address => bool) public blacklisted;
    
    // Add to blacklist
    function addToBlacklist(address account) external onlyOwner {
        blacklisted[account] = true;
    }
    
    // Remove from blacklist
    function removeFromBlacklist(address account) external onlyOwner {
        blacklisted[account] = false;
    }
    
    // Not blacklisted modifier
    modifier notBlacklisted() {
        require(!blacklisted[msg.sender], "Account is blacklisted");
        _;
    }
    
    // Emergency controls
    bool public emergencyPaused = false;
    
    // Toggle emergency pause
    function toggleEmergencyPause() external onlyOwner {
        emergencyPaused = !emergencyPaused;
    }
    
    // Not paused modifier
    modifier whenNotPaused() {
        require(!emergencyPaused, "Contract is paused");
        _;
    }
    
    // Anti-flashloan protection
    mapping(address => uint256) private lastActionTimestamp;
    uint256 public constant MIN_ACTION_DELAY = 1 minutes;
    
    // Check for flashloan
    modifier antiFlashloan() {
        require(
            lastActionTimestamp[msg.sender] == 0 || 
            block.timestamp > lastActionTimestamp[msg.sender] + MIN_ACTION_DELAY,
            "Action too soon after last action"
        );
        lastActionTimestamp[msg.sender] = block.timestamp;
        _;
    }
    
    // Re-entrancy counter
    uint256 private reentrancyCounter;
    
    // Custom re-entrancy guard
    modifier customReentrancyGuard() {
        uint256 localCounter = reentrancyCounter;
        reentrancyCounter = localCounter + 1;
        _;
        require(reentrancyCounter == localCounter + 1, "Reentrant call detected");
        reentrancyCounter = localCounter;
    }
    
    // Rate limiting
    mapping(address => mapping(bytes32 => uint256)) private actionCounts;
    mapping(bytes32 => uint256) private actionLimits;
    
    // Set action limit
    function setActionLimit(bytes32 actionType, uint256 limit) external onlyOwner {
        actionLimits[actionType] = limit;
    }
    
    // Check rate limit
    modifier rateLimit(bytes32 actionType) {
        uint256 periodStart = block.timestamp / 1 days * 1 days;
        require(
            actionCounts[msg.sender][actionType] < actionLimits[actionType] ||
            actionLimits[actionType] == 0,
            "Rate limit exceeded"
        );
        actionCounts[msg.sender][actionType]++;
        _;
    }
    
    // ======================= DEVELOPER TOOLS =======================
    
    // Event for contract version
    event ContractVersionUpdated(uint256 version, string notes);
    
    // Contract version
    uint256 public version = 1;
    string public versionNotes = "Initial release";
    
    // Update version
    function updateVersion(uint256 newVersion, string memory notes) external onlyOwner {
        version = newVersion;
        versionNotes = notes;
        
        emit ContractVersionUpdated(newVersion, notes);
    }
    
    // Contract metadata
    function getContractMetadata() external view returns (
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        uint256 circulatingSupply,
        uint256 contractVersion,
        address owner,
        uint256 deploymentTime,
        bool isPaused
    ) {
        return (
            "Multiverse Token",
            "MVT",
            MAX_SUPPLY,
            totalSupply,
            version,
            owner,
            block.timestamp - 1 days, // Mock deployment time
            emergencyPaused
        );
    }
    
    // ======================= MESSAGE SYSTEM =======================
    
    struct Message {
        address sender;
        address recipient;
        string content;
        uint256 timestamp;
        bool isRead;
    }
    
    mapping(address => Message[]) private inboxMessages;
    mapping(address => Message[]) private sentMessages;
    
    event MessageSent(address indexed sender, address indexed recipient);
    event MessageRead(address indexed recipient, uint256 messageIndex);
    
    // Send message
    function sendMessage(address recipient, string memory content) external {
        require(recipient != address(0), "Invalid recipient");
        require(bytes(content).length > 0 && bytes(content).length <= 500, "Invalid content length");
        
        Message memory newMessage = Message({
            sender: msg.sender,
            recipient: recipient,
            content: content,
            timestamp: block.timestamp,
            isRead: false
        });
        
        inboxMessages[recipient].push(newMessage);
        sentMessages[msg.sender].push(newMessage);
        
        emit MessageSent(msg.sender, recipient);
    }
    
    // Get inbox messages
    function getInboxMessages() external view returns (
        address[] memory senders,
        string[] memory contents,
        uint256[] memory timestamps,
        bool[] memory readStatus
    ) {
        Message[] storage messages = inboxMessages[msg.sender];
        
        senders = new address[](messages.length);
        contents = new string[](messages.length);
        timestamps = new uint256[](messages.length);
        readStatus = new bool[](messages.length);
        
        for (uint256 i = 0; i < messages.length; i++) {
            senders[i] = messages[i].sender;
            contents[i] = messages[i].content;
            timestamps[i] = messages[i].timestamp;
            readStatus[i] = messages[i].isRead;
        }
        
        return (senders, contents, timestamps, readStatus);
    }
    
    // Mark message as read
    function markMessageAsRead(uint256 messageIndex) external {
        require(messageIndex < inboxMessages[msg.sender].length, "Invalid message index");
        
        inboxMessages[msg.sender][messageIndex].isRead = true;
        
        emit MessageRead(msg.sender, messageIndex);
    }
    
    // ======================= ADDITIONAL GAME FEATURES =======================
    
    // Game reward multipliers
    mapping(uint256 => uint256) public gameRewardMultipliers;
    
    // Set game reward multiplier
    function setGameRewardMultiplier(uint256 gameId, uint256 multiplier) external onlyOwner {
        gameRewardMultipliers[gameId] = multiplier;
    }
    
    // Game-specific achievements
    mapping(uint256 => mapping(uint256 => Achievement)) public gameAchievements;
    mapping(uint256 => uint256) public gameAchievementCount;
    
    // Create game-specific achievement
    function createGameAchievement(
        uint256 gameId,
        string memory name,
        string memory description,
        uint256 experienceReward,
        uint256 tokenReward
    ) external onlyOwner {
        uint256 achievementId = gameAchievementCount[gameId]++;
        
        gameAchievements[gameId][achievementId] = Achievement({
            name: name,
            description: description,
            experienceReward: experienceReward,
            tokenReward: tokenReward,
            isActive: true
        });
    }
    
    // Unlock game achievement
    function unlockGameAchievement(uint256 gameId, uint256 achievementId, address player) external onlyRole(GAME_MANAGER_ROLE) {
        require(achievementId < gameAchievementCount[gameId], "Achievement does not exist");
        require(gameAchievements[gameId][achievementId].isActive, "Achievement is inactive");
        
        Achievement storage achievement = gameAchievements[gameId][achievementId];
        
        // Add experience
        addExperience(player, achievement.experienceReward);
        
        // Reward tokens
        _mint(player, achievement.tokenReward);
    }
    
    // Daily rewards
    mapping(address => uint256) public lastDailyRewardClaim;
    uint256 public dailyRewardAmount = 10 * 10**18; // 10 tokens
    
    // Claim daily reward
    function claimDailyReward() external nonReentrant {
        uint256 lastClaimDay = lastDailyRewardClaim[msg.sender] / 1 days;
        uint256 currentDay = block.timestamp / 1 days;
        
        require(currentDay > lastClaimDay, "Already claimed today");
        
        // Update claim time
        lastDailyRewardClaim[msg.sender] = block.timestamp;
        
        // Mint reward
        _mint(msg.sender, dailyRewardAmount);
        
        // Track activity
        trackUserActivity(msg.sender);
    }
    
    // Referral bonuses
    function claimReferralBonus() external nonReentrant {
        address[] storage myReferrals = referrals[msg.sender];
        require(myReferrals.length > 0, "No referrals");
        
        uint256 bonus = myReferrals.length * 5 * 10**18; // 5 tokens per referral
        
        // Mint bonus
        _mint(msg.sender, bonus);
        
        // Track activity
        trackUserActivity(msg.sender);
    }
    
    // In-game shop items
    struct ShopItem {
        string name;
        string description;
        uint256 price;
        bool isActive;
    }
    
    mapping(uint256 => ShopItem) public shopItems;
    uint256 public shopItemCount;
    
    // Add shop item
    function addShopItem(string memory name, string memory description, uint256 price) external onlyOwner {
        shopItems[shopItemCount++] = ShopItem({
            name: name,
            description: description,
            price: price,
            isActive: true
        });
    }
    
    // Purchase shop item
    function purchaseShopItem(uint256 itemId) external nonReentrant {
        require(itemId < shopItemCount, "Item does not exist");
        require(shopItems[itemId].isActive, "Item not active");
        
        uint256 price = shopItems[itemId].price;
        require(balanceOf(msg.sender) >= price, "Insufficient balance");
        
        // Transfer tokens to contract
        _transfer(msg.sender, address(this), price);
        
        // Add to treasury
        treasuryBalance += price;
        
        // Track activity
        trackUserActivity(msg.sender);
    }
    
    // ======================= FINAL UTILITY FUNCTIONS =======================
    
    // Get contract statistics
    function getContractStatistics() external view returns (
        uint256 uniquePlayers,
        uint256 totalTxs,
        uint256 totalGames,
        uint256 totalStaked,
        uint256 totalNFTs,
        uint256 totalRewards
    ) {
        return (
            totalUniquePlayers,
            totalTransactions,
            totalGamePlays,
            totalStakedTokens,
            totalNFTsMinted,
            totalRewardsPaid
        );
    }
    
    // Contract health check
    function healthCheck() external view returns (bool) {
        return (
            !emergencyPaused &&
            totalSupply() <= MAX_SUPPLY &&
            address(this).balance >= 0
        );
    }
    
    // Utility function to get timestamp
    function getBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }
    
    // Get contract balance
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    // Contract cleanup function
    function cleanup() external onlyOwner {
        // Implementation depends on specific contract requirements
    }
}


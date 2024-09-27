// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./gate/BancorFormula.sol";
import "./BondingCurveToken.sol";
import "./utils/owner/Ownable.sol";
import "./Interface/IUniswapV2Router02.sol";


contract BondingCurveManager is Ownable, BancorFormula {
    // IUniswapV2Router02 private immutable uniRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV2Router02 private immutable uniRouter = IUniswapV2Router02(0xf8e81D47203A594245E36C48e151709F0C19fBe8);
    
    struct TokenInfo {
        BondingCurveToken token;
        bool isListed;
        uint256 ethBalance;
    }
    
    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;
    // address public NeiroToken = 0xEE2a03Aa6Dacf51C18679C516ad5283d8E7C2637;
    address public NeiroToken = 0x7EF2e0048f5bAeDe046f6BF797943daF4ED8CB47;
    uint256 private feeCounter;

    IERC20 public Neiro;
    
    uint256 private constant FEE_PERCENTAGE = 100; // 1% in basis points
    uint32 private constant CONNECTOR_WEIGHT = 800000; // 70% in ppm
    // uint256 private constant MAX_POOL_BALANCE = 5 ether; // 5 eth target amount before the token is added to lp
    uint256 private constant MAX_POOL_BALANCE = 100000 * 10 ** 9; // 10K Neiro target amount before the token is added to lp
    // uint256 private constant MINIMUM_CREATION_FEE = 0.01 ether; // Fee to create a new token
    uint256 private constant MINIMUM_CREATION_FEE = 1000 * 10 ** 9; // Fee to create a new token
    uint256 private constant LP_FEE_PERCENTAGE = 500; // 5% in basis points

    address private constant LP_BURN_ADDR = 0x000000000000000000000000000000000000dEaD;
    
    event TokenCreated(address indexed tokenAddress, address indexed creator, string name, string symbol);
    event TokensBought(address indexed token, address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event TokensSold(address indexed token, address indexed seller, uint256 tokenAmount, uint256 ethAmount);
    event LiquidityAdded(address indexed token, uint256 ethAmount, uint256 tokenAmount);
    
    error InsufficientCreationFee();
    error TokenDoesNotExist();
    error TokenAlreadyListed();
    error ZeroEthSent();
    error ZeroTokenAmount();
    error FailedToSendEth();
    error NoFeesToWithdraw();

    constructor() {
        Neiro = IERC20(NeiroToken);
    }
    
    function calculateInitialSupply(uint256 ethAmount) internal pure returns (uint256) {
        // Base multiplier (tokens per ETH - for initial token supply rest are based on bonding curve)
        uint256 baseMultiplier = 297576418;
        
        // Calculating initial supply (ethAmount is in wei, so divide by 1e18 to get ETH value)
        uint256 initialSupply = (ethAmount * baseMultiplier);
        
        // logarithmic component to slightly increase token amount for larger investments
        uint256 logComponent = sqrt(ethAmount) * 1e5;
        
        return initialSupply + logComponent;
    }

    // Helper function to calculate square root
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
    
    function create(string calldata name, string calldata symbol, uint256 amountOfNeiro) external {

        if (amountOfNeiro < MINIMUM_CREATION_FEE) revert InsufficientCreationFee();

        uint256 max = type(uint256).max;

        Neiro.transferFrom(msg.sender, address(this), amountOfNeiro);
        Neiro.approve(address(uniRouter), max);

        uint256 fee = (amountOfNeiro * FEE_PERCENTAGE) / 10000;
    
        uint256 ethAfterFee = amountOfNeiro - fee;
        
        uint256 initialSupply = calculateInitialSupply(ethAfterFee);
        
        BondingCurveToken newToken = new BondingCurveToken(name, symbol);
        address tokenAddress = address(newToken);

        
        tokens[tokenAddress] = TokenInfo({
            token: newToken,
            isListed: false,
            ethBalance: ethAfterFee
        });
        tokenList.push(tokenAddress);
        
        newToken.mint(msg.sender, initialSupply);

        emit TokenCreated(tokenAddress, msg.sender, name, symbol);
    }
    
    // function buy(address tokenAddress) external payable {
    //     TokenInfo storage tokenInfo = tokens[tokenAddress];
    //     if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
    //     if (tokenInfo.isListed) revert TokenAlreadyListed();
    //     if (msg.value == 0) revert ZeroEthSent();
        
    //     uint256 fee = (msg.value * FEE_PERCENTAGE) / 10000;
    //     uint256 ethForTokens = msg.value - fee;
        
    //     uint256 tokenSupply = tokenInfo.token.totalSupply();
    //     uint256 currentBalance = tokenInfo.ethBalance;
        
    //     uint256 tokensToMint = calculatePurchaseReturn(tokenSupply, currentBalance, CONNECTOR_WEIGHT, ethForTokens);
        
    //     unchecked {
    //         tokenInfo.ethBalance = currentBalance + ethForTokens;
    //     }
        
    //     tokenInfo.token.mint(msg.sender, tokensToMint);
        
    //     emit TokensBought(tokenAddress, msg.sender, ethForTokens, tokensToMint);
        
    //     if (tokenInfo.ethBalance >= MAX_POOL_BALANCE) {
    //         _addLiquidity(tokenAddress);
    //     }
    // }

    function buyUsingNeiro(address tokenAddress, uint256 amountOfNeiro) external {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (amountOfNeiro == 0) revert ZeroEthSent();
        
        Neiro.transferFrom(msg.sender, address(this), amountOfNeiro);

        uint256 fee = (amountOfNeiro * FEE_PERCENTAGE) / 10000;
        feeCounter += fee;
        uint256 ethForTokens = amountOfNeiro - fee;
        
        uint256 tokenSupply = tokenInfo.token.totalSupply();
        uint256 currentBalance = tokenInfo.ethBalance;
        
        uint256 tokensToMint = calculatePurchaseReturn(tokenSupply, currentBalance, CONNECTOR_WEIGHT, ethForTokens);
        
        unchecked {
            tokenInfo.ethBalance = currentBalance + ethForTokens;
        }
        
        tokenInfo.token.mint(msg.sender, tokensToMint);
        
        emit TokensBought(tokenAddress, msg.sender, ethForTokens, tokensToMint);
        
        if (tokenInfo.ethBalance >= MAX_POOL_BALANCE) {
            _addLiquidity(tokenAddress);
        }
    }
    
    // function sell(address tokenAddress, uint256 tokenAmount) external {
    //     TokenInfo storage tokenInfo = tokens[tokenAddress];
    //     if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
    //     if (tokenInfo.isListed) revert TokenAlreadyListed();
    //     if (tokenAmount == 0) revert ZeroTokenAmount();
        
    //     uint256 tokenSupply = tokenInfo.token.totalSupply();
    //     uint256 currentBalance = tokenInfo.ethBalance;
        
    //     uint256 ethToReturn = calculateSaleReturn(tokenSupply, currentBalance, CONNECTOR_WEIGHT, tokenAmount);
    //     uint256 fee = (ethToReturn * FEE_PERCENTAGE) / 10000;
    //     uint256 ethAfterFee = ethToReturn - fee;
                
    //     unchecked {
    //         tokenInfo.ethBalance = currentBalance - ethToReturn;
    //     }
        
    //     tokenInfo.token.burnFrom(msg.sender, tokenAmount);
        
    //     (bool sent, ) = msg.sender.call{value: ethAfterFee}("");
    //     if (!sent) revert FailedToSendEth();
        
    //     emit TokensSold(tokenAddress, msg.sender, tokenAmount, ethAfterFee);
    // }

    function sellToNeiro(address tokenAddress, uint256 tokenAmount) external {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (tokenAmount == 0) revert ZeroTokenAmount();
        
        uint256 tokenSupply = tokenInfo.token.totalSupply();
        uint256 currentBalance = tokenInfo.ethBalance;
        
        uint256 ethToReturn = calculateSaleReturn(tokenSupply, currentBalance, CONNECTOR_WEIGHT, tokenAmount);
        uint256 fee = (ethToReturn * FEE_PERCENTAGE) / 10000;
        uint256 ethAfterFee = ethToReturn - fee;
                
        unchecked {
            tokenInfo.ethBalance = currentBalance - ethToReturn;
        }
        
        tokenInfo.token.burnFrom(msg.sender, tokenAmount);
        
        Neiro.transfer(msg.sender, ethAfterFee);
        
        emit TokensSold(tokenAddress, msg.sender, tokenAmount, ethAfterFee);
    }
    
    function _addLiquidity(address tokenAddress) internal {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        
        uint256 totalEthBalance = tokenInfo.ethBalance;
        
        uint256 lpFee = (totalEthBalance * LP_FEE_PERCENTAGE) / 10000;
        uint256 ethForLiquidity = totalEthBalance - lpFee;
        
        uint256 tokenSupply = tokenInfo.token.totalSupply();
        uint256 tokensForLiquidity = tokenSupply;
        
        tokenInfo.isListed = true;
        tokenInfo.ethBalance = 0;
        
        tokenInfo.token.mint(address(this), tokensForLiquidity);
        tokenInfo.token.approve(address(uniRouter), tokensForLiquidity);
        
        (uint256 amountToken, uint256 amountETH, ) = uniRouter.addLiquidity(
            NeiroToken,
            tokenAddress,
            ethForLiquidity,
            tokensForLiquidity,
            0,
            0,
            address(this),
            block.timestamp
        );

        tokenInfo.token.renounceOwnership();
        
        emit LiquidityAdded(tokenAddress, amountETH, amountToken);
    }
    
    // function getTokenEthBalance(address tokenAddress) external view returns (uint256) {
    //     return tokens[tokenAddress].ethBalance;
    // }

    function getTokenNeiroBalance(address tokenAddress) external view returns (uint256) {
        return tokens[tokenAddress].ethBalance;
    }
    
    // function withdrawFees() external onlyOwner {
    //     uint256 balance = address(this).balance;
    //     uint256 totalTokenBalances = 0;
    //     uint256 length = tokenList.length;
    //     for (uint256 i = 0; i < length;) {
    //         totalTokenBalances += tokens[tokenList[i]].ethBalance;
    //         unchecked { ++i; }
    //     }
    //     uint256 fees = balance - totalTokenBalances;
    //     if (fees == 0) revert NoFeesToWithdraw();
    //     (bool sent, ) = owner().call{value: fees}("");
    //     if (!sent) revert FailedToSendEth();
    // }

    function withdrawFee() external onlyOwner {
        uint256 balance = feeCounter;
        if (balance == 0) revert NoFeesToWithdraw();
        Neiro.transfer(owner(), balance);
    }

    function calculateCurvedBuyReturn(address tokenAddress, uint256 ethAmount) public view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (ethAmount == 0) revert ZeroEthSent();

        uint256 fee = (ethAmount * FEE_PERCENTAGE) / 10000;
        uint256 ethForTokens = ethAmount - fee;

        return calculatePurchaseReturn(
            tokenInfo.token.totalSupply(),
            tokenInfo.ethBalance,
            CONNECTOR_WEIGHT,
            ethForTokens
        );
    }

    function calculateCurvedSellReturn(address tokenAddress, uint256 tokenAmount) public view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();
        if (tokenAmount == 0) revert ZeroTokenAmount();

        uint256 ethToReturn = calculateSaleReturn(
            tokenInfo.token.totalSupply(),
            tokenInfo.ethBalance,
            CONNECTOR_WEIGHT,
            tokenAmount
        );
        
        uint256 fee = (ethToReturn * FEE_PERCENTAGE) / 10000;
        return ethToReturn - fee;
    }

    function calculateCurrentPrice(uint256 tokenSupply, uint256 connectorBalance) internal view returns (uint256) {
        uint256 tokenAmount = 1e9;
        uint256 ethAmount = calculateSaleReturn(tokenSupply, connectorBalance, CONNECTOR_WEIGHT, tokenAmount);
        uint256 fee = (ethAmount * FEE_PERCENTAGE) / 10000;
        return ethAmount - fee;
    }

    function getCurrentTokenPrice(address tokenAddress) public view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        if (address(tokenInfo.token) == address(0)) revert TokenDoesNotExist();
        if (tokenInfo.isListed) revert TokenAlreadyListed();

        return calculateCurrentPrice(tokenInfo.token.totalSupply(), tokenInfo.ethBalance);
    }
    
    receive() external payable {}
}
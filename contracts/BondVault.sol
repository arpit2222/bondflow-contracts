// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IBondToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

/**
 * @title BondVault
 * @dev Core smart contract for cross-chain bond trading platform
 * Manages bond issuance, pricing, minting, and redemption
 */
contract BondVault is ReentrancyGuard, Ownable {
    struct Bond {
        uint256 id;
        string name;
        uint256 principal;
        uint256 couponRate; // Annual interest rate in basis points
        uint256 maturityDate;
        address issuer;
        bool isActive;
    }

    struct UserPosition {
        uint256 bondId;
        uint256 amount;
        uint256 purchasePrice;
        uint256 purchaseDate;
    }

    IBondToken public bondToken;
    AggregatorV3Interface public priceOracle;
    
    mapping(uint256 => Bond) public bonds;
    mapping(address => UserPosition[]) public userPositions;
    mapping(uint256 => uint256) public bondPrices;
    
    uint256 public bondCounter;
    uint256 constant BASIS_POINTS = 10000;

    event BondIssued(uint256 indexed bondId, string name, uint256 principal);
    event BondMinted(address indexed user, uint256 indexed bondId, uint256 amount);
    event BondRedeemed(address indexed user, uint256 indexed bondId, uint256 amount);
    event PriceUpdated(uint256 indexed bondId, uint256 newPrice);

    /**
     * @dev Initialize vault with bond token and price oracle
     * @param _bondToken Address of the bond ERC20 token
     * @param _priceOracle Address of Chainlink price feed
     */
    constructor(address _bondToken, address _priceOracle) {
        require(_bondToken != address(0), "Invalid bond token");
        require(_priceOracle != address(0), "Invalid oracle");
        bondToken = IBondToken(_bondToken);
        priceOracle = AggregatorV3Interface(_priceOracle);
    }

    /**
     * @dev Issue new bond with specified parameters
     * @param _name Bond name
     * @param _principal Principal amount
     * @param _couponRate Annual coupon rate in basis points
     * @param _maturityDate Unix timestamp of maturity
     */
    function issueBond(
        string memory _name,
        uint256 _principal,
        uint256 _couponRate,
        uint256 _maturityDate
    ) external onlyOwner returns (uint256) {
        require(_principal > 0, "Invalid principal");
        require(_maturityDate > block.timestamp, "Invalid maturity date");
        require(_couponRate < BASIS_POINTS, "Coupon rate too high");

        bondCounter++;
        Bond storage bond = bonds[bondCounter];
        bond.id = bondCounter;
        bond.name = _name;
        bond.principal = _principal;
        bond.couponRate = _couponRate;
        bond.maturityDate = _maturityDate;
        bond.issuer = msg.sender;
        bond.isActive = true;

        emit BondIssued(bondCounter, _name, _principal);
        return bondCounter;
    }

    /**
     * @dev Get current bond price from oracle with yield adjustments
     * @param _bondId ID of the bond
     * @return Current price of the bond
     */
    function getBondPrice(uint256 _bondId) public view returns (uint256) {
        require(bonds[_bondId].isActive, "Bond not active");
        
        (, int256 price, , , ) = priceOracle.latestRoundData();
        require(price > 0, "Invalid oracle price");

        Bond storage bond = bonds[_bondId];
        uint256 timeToMaturity = bond.maturityDate > block.timestamp 
            ? bond.maturityDate - block.timestamp 
            : 0;
        
        // Calculate price based on yield to maturity
        uint256 yieldSpread = (bond.couponRate * timeToMaturity) / 365 days;
        uint256 adjustedPrice = (bond.principal * (BASIS_POINTS + yieldSpread)) / BASIS_POINTS;
        
        return adjustedPrice;
    }

    /**
     * @dev Mint bonds for user with reentrancy protection
     * @param _bondId ID of bond to mint
     * @param _amount Number of bonds to mint
     */
    function mintBonds(uint256 _bondId, uint256 _amount) external nonReentrant {
        require(bonds[_bondId].isActive, "Bond not active");
        require(_amount > 0, "Invalid amount");

        uint256 price = getBondPrice(_bondId);
        uint256 totalCost = (_amount * price) / 10**18;

        // Transfer payment from user
        require(
            bondToken.transferFrom(msg.sender, address(this), totalCost),
            "Payment transfer failed"
        );

        // Record position
        UserPosition memory position = UserPosition({
            bondId: _bondId,
            amount: _amount,
            purchasePrice: price,
            purchaseDate: block.timestamp
        });
        
        userPositions[msg.sender].push(position);
        emit BondMinted(msg.sender, _bondId, _amount);
    }

    /**
     * @dev Redeem bond at or after maturity
     * @param _bondId ID of bond to redeem
     * @param _positionIndex Index of user position
     */
    function redeemBond(uint256 _bondId, uint256 _positionIndex) external nonReentrant {
        require(_positionIndex < userPositions[msg.sender].length, "Invalid position");
        
        UserPosition memory position = userPositions[msg.sender][_positionIndex];
        require(position.bondId == _bondId, "Position bond mismatch");
        require(bonds[_bondId].maturityDate <= block.timestamp, "Bond not matured");

        uint256 accrued = calculateAccruedInterest(position);
        uint256 totalPayout = position.amount + accrued;

        // Remove position
        userPositions[msg.sender][_positionIndex] = userPositions[msg.sender][
            userPositions[msg.sender].length - 1
        ];
        userPositions[msg.sender].pop();

        // Transfer principal + interest
        require(bondToken.transfer(msg.sender, totalPayout), "Redemption payout failed");
        emit BondRedeemed(msg.sender, _bondId, totalPayout);
    }

    /**
     * @dev Calculate accrued interest on a position
     * @param position User position struct
     * @return Accrued interest amount
     */
    function calculateAccruedInterest(UserPosition memory position) 
        internal 
        view 
        returns (uint256) 
    {
        Bond storage bond = bonds[position.bondId];
        uint256 holdingPeriod = block.timestamp > bond.maturityDate 
            ? bond.maturityDate - position.purchaseDate
            : block.timestamp - position.purchaseDate;

        return (position.amount * bond.couponRate * holdingPeriod) / 
               (BASIS_POINTS * 365 days);
    }

    /**
     * @dev Get all positions for a user
     * @param _user User address
     * @return Array of user positions
     */
    function getUserPositions(address _user) 
        external 
        view 
        returns (UserPosition[] memory) 
    {
        return userPositions[_user];
    }

    /**
     * @dev Get bond details
     * @param _bondId ID of bond
     * @return Bond struct with all details
     */
    function getBond(uint256 _bondId) 
        external 
        view 
        returns (Bond memory) 
    {
        require(bonds[_bondId].isActive, "Bond not found");
        return bonds[_bondId];
    }
}

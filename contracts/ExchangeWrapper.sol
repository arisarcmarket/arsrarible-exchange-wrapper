pragma solidity 0.7.6;
pragma abicoder v2;
import "@rarible/transfer-manager/contracts/lib/LibTransfer.sol";
import "@rarible/lib-bp/contracts/BpLibrary.sol";
import "@rarible/lib-part/contracts/LibPart.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155Holder.sol";
import "./interfaces/IWyvernExchange.sol";
import "./interfaces/IExchangeV2.sol";
import "./interfaces/ISeaPort.sol";
import "./interfaces/Ix2y2.sol";
import "./interfaces/ILooksRare.sol";
import "./libraries/IsPausable.sol";

contract ArsExchangeWrapper is Ownable, ERC721Holder, ERC1155Holder, IsPausable {
	using LibTransfer for address;
	using BpLibrary for uint;
	using SafeMath for uint;
	address public wyvernExchange;
	address public exchangeV2;
	address public seaPort;
	address public x2y2;
	address public looksRare;
	address public sudoswap;
	event Execution(bool result);

	enum Markets {
		ExchangeV2,
		WyvernExchange,
		SeaPort,
		X2Y2,
		LooksRareOrders,
		SudoSwap
	}

	struct PurchaseDetails {
		Markets marketId;
		uint256 amount;
		uint fees;
		bytes data;
	}

	constructor(address _wyvernExchange, address _exchangeV2, address _seaPort, address _x2y2, address _looksRare, address _sudoswap) default {
		wyvernExchange = _wyvernExchange;
		exchangeV2 = _exchangeV2;
		seaPort = _seaPort;
		x2y2 = _x2y2;
		looksRare = _looksRare;
		sudoswap = _sudoswap;
	}

	function singlePurchase(PurchaseDetails memory purchaseDetails, address feeRecipientFirst, address feeRecipientSecond) external payable {
		requireNotPaused();
		(bool success, uint feeAmountFirst, uint feeAmountSecond) = purchase(purchaseDetails, false);
		emit Execution(success);
		transferFee(feeAmountFirst, feeRecipientFirst);
		transferFee(feeAmountSecond, feeRecipientSecond);
		transferChange();
	}

	function bulkPurchase(PurchaseDetails[] memory purchaseDetails, address feeRecipientFirst, address feeRecipientSecond, bool allowFail) external payable {
		requireNotPaused();
		uint sumFirstFees = 0;
		uint sumSecondFees = 0;
		bool result = false;
		for (uint i = 0; i < purchaseDetails.length; i++) {
			(bool success, uint firstFeeAmount, uint secondFeeAmount) = purchase(purchaseDetails[i], allowFail);
			result = result || success;
			emit Execution(success);
			sumFirstFees = sumFirstFees.add(firstFeeAmount);
			sumSecondFees = sumSecondFees.add(secondFeeAmount);
		}
		require(result, "no successful executions");
		transferFee(sumFirstFees, feeRecipientFirst);
		transferFee(sumSecondFees, feeRecipientSecond);
		transferChange();
	}

	function purchase(PurchaseDetails memory purchaseDetails, bool allowFail) internal returns(bool, uint, uint) {
		uint paymentAmount = purchaseDetails.amount;
		if (purchaseDetails.marketId == Markets.SeaPort) {
			(bool success, ) = address(seaPort).call {value: paymentAmount}(purchaseDetails.data);
			if (allowFail) {
				if (!success) {
					return (false, 0, 0);
				}
			} else {
				require(success, "Purchase SeaPort failed");
			}
		} else if (purchaseDetails.marketId == Markets.WyvernExchange) {
			(bool success, ) = address(wyvernExchange).call {value: paymentAmount}(purchaseDetails.data);
			if (allowFail) {
				if (!success) {
					return (false, 0, 0);
				}
			} else {
				require(success, "Purchase wyvernExchange failed");
			}
		} else if (purchaseDetails.marketId == Markets.ExchangeV2) {
			(bool success, ) = address(exchangeV2).call {value: paymentAmount}(purchaseDetails.data);
			if (allowFail) {
				if (!success) {
					return (false, 0, 0);
				}
			} else {
				require(success, "Purchase rarible failed");
			}
		} else if (purchaseDetails.marketId == Markets.X2Y2) {
			Ix2y2.RunInput memory input = abi.decode(purchaseDetails.data, (Ix2y2.RunInput));
			if (allowFail) {

			} else {
				Ix2y2(x2y2).run {value: paymentAmount}(input);
			}
			for (uint i = 0; i < input.orders.length; i++) {
				for (uint j = 0; j < input.orders[i].items.length; j++) {
					Ix2y2.Pair[] memory pairs = abi.decode(input.orders[i].items[j].data, (Ix2y2.Pair[]));
					for (uint256 k = 0; k < pairs.length; k++) {
						Ix2y2.Pair memory p = pairs[k];
						IERC721Upgradeable(address(p.token)).safeTransferFrom(address(this), _msgSender(), p.tokenId);
					}
				}
			}
		} else if (purchaseDetails.marketId == Markets.LooksRareOrders) {
			(LibLooksRare.TakerOrder memory takerOrder, LibLooksRare.MakerOrder memory makerOrder, bytes4 typeNft) = abi.decode(purchaseDetails.data, (LibLooksRare.TakerOrder, LibLooksRare.MakerOrder, bytes4));
			if (allowFail) {

			} else {
				ILooksRare(looksRare).matchAskWithTakerBidUsingETHAndWETH {value: paymentAmount}(takerOrder, makerOrder);
			}
			if (typeNft == LibAsset.ERC721_ASSET_CLASS) {
				IERC721Upgradeable(makerOrder.collection).safeTransferFrom(address(this), _msgSender(), makerOrder.tokenId);
			} else if (typeNft == LibAsset.ERC1155_ASSET_CLASS) {
				IERC1155Upgradeable(makerOrder.collection).safeTransferFrom(address(this), _msgSender(), makerOrder.tokenId, makerOrder.amount, "");
			} else {
				revert("Unknown token type");
			}
		} else if (purchaseDetails.marketId == Markets.SudoSwap) {
			(bool success, ) = address(sudoswap).call {value: paymentAmount}(purchaseDetails.data);
			if (allowFail) {
				if (!success) {
					return (false, 0, 0);
				}
			} else {
				require(success, "Purchase sudoswap failed");
			}
		} else {
			revert("Unknown purchase details");
		}
		(uint firstFeeAmount, uint secondFeeAmount) = getFees(purchaseDetails.fees, purchaseDetails.amount);
		return (true, firstFeeAmount, secondFeeAmount);
	}

	function transferFee(uint feeAmount, address feeRecipient) internal {
		if (feeAmount > 0 && feeRecipient != address(0)) {
			LibTransfer.transferEth(feeRecipient, feeAmount);
		}
	}

	function transferChange() internal {
		uint ethAmount = address(this).balance;
		if (ethAmount > 0) {
			address(msg.sender).transferEth(ethAmount);
		}
	}

	function getFees(uint fees, uint amount) internal pure returns(uint, uint) {
		uint firstFee = uint(uint16(fees >> 16));
		uint secondFee = uint(uint16(fees));
		return (amount.bp(firstFee), amount.bp(secondFee));
	}

	function() external payable {

	}

	function ArsEx() public pure returns(string memory) {
		return "This is My First Exchange";
	}
}
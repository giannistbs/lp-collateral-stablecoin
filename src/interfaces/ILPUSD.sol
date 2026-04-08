// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title ILPUSD
 * @author Ioannis Tampakis
 * @notice Interface for the LPUSD stablecoin protocol extensions — mint, burn, and the
 *         VaultManager binding. Standard ERC-20 functionality is provided by the
 *         OpenZeppelin ERC20 base contract in the implementation.
 */
interface ILPUSD {
  /*///////////////////////////////////////////////////////////////
                            ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when a caller other than the VaultManager attempts to mint or burn
   */
  error LPUSD_OnlyVaultManager();

  /**
   * @notice Thrown when the zero address is passed as the VaultManager
   */
  error LPUSD_ZeroAddress();

  /*///////////////////////////////////////////////////////////////
                            LOGIC
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Mints LPUSD tokens to a recipient
   * @dev Only callable by VAULT_MANAGER
   * @param _to Recipient of the newly minted tokens
   * @param _amount Amount to mint (18 decimals)
   */
  function mint(address _to, uint256 _amount) external;

  /**
   * @notice Burns LPUSD tokens from an account
   * @dev Only callable by VAULT_MANAGER. The VaultManager must have been granted an allowance
   *      or directly hold the tokens.
   * @param _from Account to burn tokens from
   * @param _amount Amount to burn (18 decimals)
   */
  function burn(address _from, uint256 _amount) external;

  /*///////////////////////////////////////////////////////////////
                            VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the address of the VaultManager — the sole authorised minter/burner
   * @return _vaultManager The VaultManager address
   */
  function VAULT_MANAGER() external view returns (address _vaultManager);
}

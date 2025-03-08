module pausable::pause_control {
  use std::signer;
  use std::string::String;
  use aptos_std::smart_table::{Self, SmartTable};
  use aptos_framework::event;

  #[event]
  /// Event emitted when a contract is paused
  struct Paused has store, drop {
    account: address,
    contract: String,
  }

  #[event]
  /// Event emitted when a contract is unpaused
  struct Unpaused has store, drop {
    account: address,
    contract: String,
  }

  struct Pausable has key {
    pausable_instance: SmartTable<String, bool>,
  }

  #[view]
  /// Checks if a given contract is paused under an account
  public fun is_paused(account: address, contract: String): bool acquires Pausable {
    if (!exists<Pausable>(account)) {
      false
    } else {
      let pausable = borrow_global<Pausable>(account);
      // Check if the contract exists in the pausable_instance table
      if (smart_table::contains(&pausable.pausable_instance, contract)) {
        *(smart_table::borrow(&pausable.pausable_instance, contract))
      } else {
        false // Default to false if contract is not found
      }
    }
  }

  public entry fun pause(account: &signer, contract: String) acquires Pausable {
    let account_address = signer::address_of(account);
    if (!exists<Pausable>(account_address)) {
      move_to(account, Pausable { pausable_instance: smart_table::new<String, bool>() });
    };
    let pausable = borrow_global_mut<Pausable>(account_address);
    smart_table::upsert(&mut pausable.pausable_instance, contract, true);
    event::emit(Paused { account: account_address, contract });
  }

  public entry fun unpause(account: &signer, contract: String) acquires Pausable {
    let account_address = signer::address_of(account);
    if (!exists<Pausable>(account_address)) {
      move_to(account, Pausable { pausable_instance: smart_table::new<String, bool>() });
    };
    let pausable = borrow_global_mut<Pausable>(account_address);
    smart_table::upsert(&mut pausable.pausable_instance, contract, false);
    event::emit(Unpaused { account: account_address, contract });
  }
}

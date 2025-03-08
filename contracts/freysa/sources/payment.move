module freysa::payment_v1 {
  use std::signer;
  use std::string;
  use std::fixed_point32;
  use std::string::String;
  use std::vector;
  use aptos_std::math64;
  use aptos_std::smart_vector;
  use aptos_std::smart_vector::SmartVector;
  use aptos_std::string_utils;
  use aptos_std::type_info;
  use aptos_framework::aptos_coin::AptosCoin;
  use aptos_framework::event;
  use aptos_framework::coin;
  use aptos_framework::fungible_asset::Metadata;
  use aptos_framework::object;
  use aptos_framework::object::{Object};
  use aptos_framework::primary_fungible_store;
  use pausable::pause_control;

  const CONTRACT_NAME: vector<u8> = b"FREYSA_PAYMENT_V1";
  const ONE_APTOS: u64 = 1_00_000_000;

  /// Invalid fees data.
  const ENOT_FEES_DATA: u64 = 1;
  /// Invalid whitelist token
  const EINVALID_TOKEN: u64 = 2;

  // https://move-developers-dao.gitbook.io/aptos-move-by-example/basic-concepts/struct-and-its-abilities
  // https://aptos.dev/en/build/smart-contracts/book/abilities
  // Copy - value can be copied (or cloned by value).
  // Drop - value can be dropped by the end of scope.
  // Key - value can be used as a key for global storage operations. It gates all global storage operations, so in order for a type to be used with move_to, borrow_global, move_from, etc.
  // Store - value can be stored inside global storage.
  #[event]
  struct BuyInEvent has store, drop {
    user: address,
    hashed_prompt: vector<u8>,
    amount: u64,
    // token_received: u256,
  }

  #[event]
  struct ChapterCreatedEvent has store, drop {
    chapter_id: u64,
    creator: address,
    team_fee_recipient: address,
    pool_fee_recipient: address,

    fee_structure: vector<u64>,
    fee_denominator: u64,

    current_payment_amount: u64,
    max_payment_amount: u64,

    payment_increase_ratio: u64,
    payment_increase_denominator: u64,
  }

  struct PaymentConfigs has key, store {
    payment_configs: SmartVector<PaymentConfig>,
  }

  struct PaymentConfig has key, store, copy, drop {
    whitelist_token: String,          // Whitelisted token for the chapter
    total_payment_amount: u64,        // Total payment amount for the chapter
    pool_fee_amount: u64,             // Pool fee amount for the chapter
    team_fee_amount: u64,             // Team fee amount for the chapter

    team_fee_recipient: address,      // Address of the team receiving the fee
    pool_fee_recipient: address,      // Address of the pool receiving the fee
    
    fee_denominator: u64,             // Denominator for calculating fees
    fee_structure: vector<u64>,       // List of fee amounts for different stages

    current_payment_amount: u64,      // Current payment amount for submitting a prompt
    max_payment_amount: u64,          // Maximum possible payment amount
    
    payment_increase_ratio: u64,      // Ratio by which payment increases
    payment_increase_denominator: u64 // Denominator for payment increase calculation
  }

  // struct ReserveData has key, store, copy, drop {
  // }

  public entry fun update_team_fee_recipient(
    admin: &signer, 
    new_recipient: address, 
    chapter_id: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    require_funds_admin(signer::address_of(admin));

    let payment_config = get_payment_config_mut(chapter_id);
    payment_config.team_fee_recipient = new_recipient;
  }

  public entry fun update_pool_fee_recipient(
    admin: &signer, 
    new_recipient: address, 
    chapter_id: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    require_funds_admin(signer::address_of(admin));

    let payment_config = get_payment_config_mut(chapter_id);
    payment_config.pool_fee_recipient = new_recipient;
  }

  public entry fun update_fee_structure(
    admin: &signer, 
    new_fees: vector<u64>, 
    chapter_id: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    assert!(vector::length(&new_fees) >= 2, ENOT_FEES_DATA);
    require_funds_admin(signer::address_of(admin));

    let payment_config = get_payment_config_mut(chapter_id);
    payment_config.fee_structure = new_fees;
  }

  public entry fun update_fee_denominator(
    admin: &signer, 
    new_denominator: u64, 
    chapter_id: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    require_funds_admin(signer::address_of(admin));

    let payment_config = get_payment_config_mut(chapter_id);
    payment_config.fee_denominator = new_denominator;
  }

  public entry fun update_payment_increase_factors(
    admin: &signer, 
    new_ratio: u64, 
    new_denominator: u64, 
    chapter_id: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    require_funds_admin(signer::address_of(admin));

    let payment_config = get_payment_config_mut(chapter_id);
    payment_config.payment_increase_ratio = new_ratio;
    payment_config.payment_increase_denominator = new_denominator;
  }

  public entry fun update_max_payment_amount(
    admin: &signer, 
    new_max_amount: u64, 
    chapter_id: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    require_funds_admin(signer::address_of(admin));

    let payment_config = get_payment_config_mut(chapter_id);
    payment_config.max_payment_amount = new_max_amount;
  }

  public entry fun set_new_admin(admin: &signer, new_admin: address) {
    require_not_paused();
    acl::acl_manage::add_funds_admin(admin, new_admin);
  }

  /**
   * Throws if the contract is paused.
   */
  public fun require_not_paused() {
    assert!(
      !pause_control::is_paused(@deployer, contract_name()),
      1,
    );
  }

  /**
   * Throws if the address is not admin.
   */
  public fun require_funds_admin(admin: address) {
    acl::acl_manage::is_funds_admin(admin);
  }

  #[view]
  public fun contract_name(): string::String {
    string::utf8(CONTRACT_NAME)
  }

  #[view]
  public fun max_payment_amount(chapter: u64): u64 acquires PaymentConfigs {
    get_payment_config(chapter).max_payment_amount
  }

  #[view]
  public fun get_deployer(): address {
    @deployer
  }

  #[view]
  public fun get_pool_info(chapter: u64): (address, address, vector<u64>, u64, u64, u64, u64, u64, u64, u64, u64, String) acquires PaymentConfigs {
    (
      get_payment_config(chapter).team_fee_recipient,
      get_payment_config(chapter).pool_fee_recipient,
      get_payment_config(chapter).fee_structure,
      get_payment_config(chapter).fee_denominator,
      get_payment_config(chapter).current_payment_amount,
      get_payment_config(chapter).max_payment_amount,
      get_payment_config(chapter).payment_increase_ratio,
      get_payment_config(chapter).payment_increase_denominator,
      get_payment_config(chapter).pool_fee_amount,
      get_payment_config(chapter).team_fee_amount,
      get_payment_config(chapter).total_payment_amount,
      get_payment_config(chapter).whitelist_token,
    )
  }

  fun init_module(deployer: &signer) {

    // acl::acl_manage::add_funds_admin(deployer, signer::address_of(deployer));
    // whitelist aptos coin as default token
    // init default chapter
    let payment_configs = smart_vector::new<PaymentConfig>();
    smart_vector::push_back(&mut payment_configs, PaymentConfig {
      whitelist_token: type_info::type_name<AptosCoin>(),
      total_payment_amount: 0,
      pool_fee_amount: 0,
      team_fee_amount: 0,
      team_fee_recipient: signer::address_of(deployer),
      pool_fee_recipient: signer::address_of(deployer),
      fee_structure: vector[3000, 7000],
      fee_denominator: 10000,
      current_payment_amount: 1 * ONE_APTOS,
      max_payment_amount: 5 * ONE_APTOS,
      payment_increase_ratio: 7,
      payment_increase_denominator: 100,
    });

    move_to(deployer, PaymentConfigs {
      payment_configs
    });
  }

  public entry fun create_chapter<CoinType>(
    admin: &signer,
    team_fee_recipient: address,
    pool_fee_recipient: address,
    fee_structure: vector<u64>,
    fee_denominator: u64,
    initial_payment: u64,
    max_payment_amount: u64,
    payment_increase_ratio: u64,
    payment_increase_denominator: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    require_funds_admin(signer::address_of(admin));

    let payment_configs = get_payment_configs_mut();
    let chapter_id = smart_vector::length(&payment_configs.payment_configs) - 1;
    event::emit(ChapterCreatedEvent {
      chapter_id,
      creator: signer::address_of(admin),
      team_fee_recipient,
      pool_fee_recipient,
      fee_structure,
      fee_denominator,
      current_payment_amount: initial_payment,
      max_payment_amount,
      payment_increase_ratio,
      payment_increase_denominator,
    });
    smart_vector::push_back(&mut payment_configs.payment_configs, PaymentConfig {
      whitelist_token: type_info::type_name<CoinType>(),
      total_payment_amount: 0,
      pool_fee_amount: 0,
      team_fee_amount: 0,
      team_fee_recipient,
      pool_fee_recipient,
      fee_structure,
      fee_denominator,
      current_payment_amount: initial_payment,
      max_payment_amount,
      payment_increase_ratio,
      payment_increase_denominator,
    });
  }

  public entry fun buy_in<CoinType>(
    account: &signer,
    hashed_prompt: vector<u8>,
    chapter: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    asset_whitelisted_token_by_chapter(type_info::type_name<CoinType>(), chapter);

    let sender_address = signer::address_of(account);
    let payment_config = get_payment_config_mut(chapter);
    
    let team_fee_ratio = vector::borrow(&payment_config.fee_structure, 0);
    let pool_fee_ratio = vector::borrow(&payment_config.fee_structure, 1);
    let current_payment = payment_config.current_payment_amount;

    // Transfer to team
    let team_fee = fixed_point32::create_from_rational(*team_fee_ratio, payment_config.fee_denominator);
    let amount_to_team = fixed_point32::multiply_u64(current_payment, team_fee);
    coin::transfer<CoinType>(account, payment_config.team_fee_recipient, amount_to_team);
  
    // Transfer to pool
    let pool_fee = fixed_point32::create_from_rational(*pool_fee_ratio, payment_config.fee_denominator);
    let amount_to_pool = fixed_point32::multiply_u64(current_payment, pool_fee);
    coin::transfer<CoinType>(account, payment_config.pool_fee_recipient, amount_to_pool); // Fixed incorrect recipient

    // Increase payment amount for the next buy-in
    payment_config.current_payment_amount = payment_config.current_payment_amount +
      math64::mul_div(payment_config.current_payment_amount, payment_config.payment_increase_ratio, payment_config.payment_increase_denominator);

    // Increase payment amount for the chapter
    payment_config.total_payment_amount = payment_config.total_payment_amount + current_payment;
    payment_config.pool_fee_amount = payment_config.pool_fee_amount + amount_to_pool;
    payment_config.team_fee_amount = payment_config.team_fee_amount + amount_to_team;

    // Cap the payment amount at max_payment_amount
    if (payment_config.current_payment_amount > payment_config.max_payment_amount) {
      payment_config.current_payment_amount = payment_config.max_payment_amount;
    };

    event::emit(BuyInEvent {
      user: sender_address,
      hashed_prompt,
      amount: current_payment,
    });
  }

  public entry fun buy_in_fa(
    user: &signer,
    token: Object<Metadata>,
    hashed_prompt: vector<u8>,
    chapter_id: u64
  ) acquires PaymentConfigs {
    require_not_paused();
    asset_whitelisted_token_by_chapter(format_fungible_asset(token), chapter_id);

    let sender_address = signer::address_of(user);
    let payment_config = get_payment_config_mut(chapter_id);
    
    let team_fee_ratio = vector::borrow(&payment_config.fee_structure, 0);
    let pool_fee_ratio = vector::borrow(&payment_config.fee_structure, 1);
    let current_payment = payment_config.current_payment_amount;

    // Transfer to team
    let team_fee = fixed_point32::create_from_rational(*team_fee_ratio, payment_config.fee_denominator);
    let amount_to_team = fixed_point32::multiply_u64(current_payment, team_fee);
    primary_fungible_store::transfer(user, token, payment_config.team_fee_recipient, amount_to_team);

    // Transfer to pool
    let pool_fee = fixed_point32::create_from_rational(*pool_fee_ratio, payment_config.fee_denominator);
    let amount_to_pool = fixed_point32::multiply_u64(current_payment, pool_fee);
    primary_fungible_store::transfer(user, token, payment_config.pool_fee_recipient, amount_to_pool);

    // Update payment amount for next buy-in
    payment_config.current_payment_amount = payment_config.current_payment_amount +
      math64::mul_div(payment_config.current_payment_amount, payment_config.payment_increase_ratio, payment_config.payment_increase_denominator);

    // Cap the payment amount at max_payment_amount
    if (payment_config.current_payment_amount > payment_config.max_payment_amount) {
      payment_config.current_payment_amount = payment_config.max_payment_amount;
    };

    event::emit(BuyInEvent {
      user: sender_address,
      hashed_prompt,
      amount: current_payment,
    });
  }

  inline fun asset_whitelisted_token_by_chapter(token: String, chapter: u64) {
    let config = get_payment_config_mut(chapter);
    assert!(config.whitelist_token == token, EINVALID_TOKEN);
  }

  public fun format_fungible_asset(fungible_asset: Object<Metadata>): String {
    let fa_address = object::object_address(&fungible_asset);
    // This will create "@0x123"
    let fa_address_str = string_utils::to_string(&fa_address);
    // We want to strip the prefix "@"
    string::sub_string(&fa_address_str, 1, string::length(&fa_address_str))
  }

  inline fun get_payment_config_mut(chapter: u64): &mut PaymentConfig {
    smart_vector::borrow_mut(&mut borrow_global_mut<PaymentConfigs>(@deployer).payment_configs, chapter)
  }

  inline fun get_payment_config(chapter: u64): &PaymentConfig {
    smart_vector::borrow(&mut borrow_global_mut<PaymentConfigs>(@deployer).payment_configs, chapter)
  }

  inline fun get_payment_configs_mut(): &mut PaymentConfigs {
    borrow_global_mut<PaymentConfigs>(@deployer)
  }

  inline fun get_payment_configs(): &PaymentConfigs {
    borrow_global<PaymentConfigs>(@deployer)
  }
}

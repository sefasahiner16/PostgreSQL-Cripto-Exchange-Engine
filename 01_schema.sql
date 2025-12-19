-- ==========================================
-- 1. CLEAN UP
-- ==========================================

DROP MATERIALIZED VIEW IF EXISTS mv_ohlcv_1min CASCADE;
DROP TABLE IF EXISTS market_trades CASCADE;
DROP TABLE IF EXISTS wallet_audit_logs CASCADE;
DROP TRIGGER IF EXISTS trg_match_orders ON orders;
DROP TRIGGER IF EXISTS trg_audit_wallets ON wallets;
DROP FUNCTION IF EXISTS sp_match_orders CASCADE;
DROP FUNCTION IF EXISTS sp_cancel_order CASCADE;
DROP FUNCTION IF EXISTS sp_place_order CASCADE;
DROP FUNCTION IF EXISTS sp_log_wallet_changes CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS wallets CASCADE;
DROP TABLE IF EXISTS currencies CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS market_prices CASCADE;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ==========================================
-- 2. TABLES
-- ==========================================

-- USERS
CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- CURRENCIES
CREATE TABLE currencies (
    currency_code VARCHAR(10) PRIMARY KEY,
    currency_name VARCHAR(50),
    is_fiat BOOLEAN DEFAULT FALSE
);

-- WALLETS
CREATE TABLE wallets (
    wallet_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(user_id) ON DELETE CASCADE,
    currency_code VARCHAR(10) REFERENCES currencies(currency_code),
    available_balance DECIMAL(18, 8) DEFAULT 0 CHECK (available_balance >= 0),
    locked_balance DECIMAL(18, 8) DEFAULT 0 CHECK (locked_balance >= 0),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, currency_code)
);

-- AUDIT LOGS
CREATE TABLE wallet_audit_logs (
    log_id SERIAL PRIMARY KEY,
    wallet_id UUID REFERENCES wallets(wallet_id) ON DELETE CASCADE,
    currency_code VARCHAR(10),
    operation_type VARCHAR(20),
    old_balance DECIMAL(18, 8),
    new_balance DECIMAL(18, 8),
    old_locked DECIMAL(18, 8),
    new_locked DECIMAL(18, 8),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ORDERS
CREATE TABLE orders (
    order_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(user_id),
    pair VARCHAR(20) NOT NULL,
    order_side VARCHAR(4) CHECK (order_side IN ('BUY', 'SELL')),
    order_type VARCHAR(10) DEFAULT 'LIMIT',
    price DECIMAL(18, 8) NOT NULL,
    original_amount DECIMAL(18, 8) NOT NULL,
    filled_amount DECIMAL(18, 8) DEFAULT 0,
    status VARCHAR(20) DEFAULT 'OPEN',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- MARKET PRICES
CREATE TABLE market_prices (
    pair VARCHAR(20) PRIMARY KEY,
    current_price DECIMAL(18, 8),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- MARKET TRADES
CREATE TABLE market_trades (
    trade_id SERIAL PRIMARY KEY,
    pair VARCHAR(20) NOT NULL,
    price DECIMAL(18, 8) NOT NULL,
    amount DECIMAL(18, 8) NOT NULL,
    buyer_order_id UUID REFERENCES orders(order_id) ON DELETE SET NULL,
    seller_order_id UUID REFERENCES orders(order_id) ON DELETE SET NULL,
    traded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ==========================================
-- 3. VIEW VE INDEXES
-- ==========================================

CREATE MATERIALIZED VIEW mv_ohlcv_1min AS
SELECT pair, date_trunc('minute', traded_at) as bucket_time,
    (array_agg(price ORDER BY traded_at ASC))[1] as open_price,
    MAX(price) as high_price, MIN(price) as low_price,
    (array_agg(price ORDER BY traded_at DESC))[1] as close_price,
    SUM(amount) as volume
FROM market_trades GROUP BY pair, bucket_time ORDER BY bucket_time DESC;

CREATE INDEX idx_ohlcv_pair_time ON mv_ohlcv_1min (pair, bucket_time);
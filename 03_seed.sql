DO $$
DECLARE
    v_ahmet UUID;
    v_ayse UUID;
BEGIN
    -- CLEARING TABLES BEFORE START
    DELETE FROM orders;
    DELETE FROM wallets;
    DELETE FROM users;

    -- INSERTING THE CURRENCIES IF THEY HAD NOT BEEN
    INSERT INTO currencies (currency_code, currency_name, is_fiat) VALUES
    ('BTC', 'Bitcoin', FALSE),
    ('USDT', 'Tether', FALSE)
    ON CONFLICT (currency_code) DO NOTHING; -- Zaten varsa hata verme, geç.

    -- INSERTING IN THE MARKET VALUES, THEY WILL CHANGE AS THE EXCHANGES HAPPEN
    INSERT INTO market_prices (pair, current_price) VALUES
    ('BTC/USDT', 95000.00)
    ON CONFLICT (pair) DO UPDATE
    SET current_price = EXCLUDED.current_price;

    -- CREATING THE USERS
    INSERT INTO users (email, password_hash) VALUES ('ahmet@sat.com', '123') RETURNING user_id INTO v_ahmet;
    INSERT INTO users (email, password_hash) VALUES ('ayse@al.com', '123') RETURNING user_id INTO v_ayse;

    -- SETTING UP WALLETS
    -- GIVING AHMET 1 BITCOIN, HE WILL SELL
    INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (v_ahmet, 'BTC', 100.0);
    INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (v_ahmet, 'USDT', 1000000.0);
    -- GIVING AYSE 100000 USDT, SHE WILL BUY
    INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (v_ayse, 'USDT', 1000000.0);
    INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (v_ayse, 'BTC', 100.0);
END $$

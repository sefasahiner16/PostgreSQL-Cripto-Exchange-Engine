-- ==========================================
-- 1. STORED PROCEDURES
-- ==========================================

-- PLACE ORDER
CREATE OR REPLACE FUNCTION sp_place_order(
    p_user_id UUID, p_pair VARCHAR, p_side VARCHAR, p_price DECIMAL, p_amount DECIMAL
)
RETURNS UUID AS $$
DECLARE
    v_final_price DECIMAL; v_order_id UUID; v_total_cost DECIMAL;
    v_base_currency VARCHAR(10); v_quote_currency VARCHAR(10);
BEGIN
    IF p_price IS NULL OR p_price = 0 THEN
        SELECT current_price INTO v_final_price FROM market_prices WHERE pair = p_pair;
        IF v_final_price IS NULL THEN RAISE EXCEPTION 'Price could not found!'; END IF;
    ELSE v_final_price := p_price; END IF;

    v_base_currency := split_part(p_pair, '/', 1);
    v_quote_currency := split_part(p_pair, '/', 2);

    IF p_side = 'BUY' THEN
        v_total_cost := v_final_price * p_amount;
        UPDATE wallets SET available_balance = available_balance - v_total_cost, locked_balance = locked_balance + v_total_cost
        WHERE user_id = p_user_id AND currency_code = v_quote_currency AND available_balance >= v_total_cost;
        IF NOT FOUND THEN RAISE EXCEPTION 'USDT Balance is not enough!'; END IF;
    ELSE
        UPDATE wallets SET available_balance = available_balance - p_amount, locked_balance = locked_balance + p_amount
        WHERE user_id = p_user_id AND currency_code = v_base_currency AND available_balance >= p_amount;
        IF NOT FOUND THEN RAISE EXCEPTION 'COIN Balance is not enough!'; END IF;
    END IF;

    INSERT INTO orders (user_id, pair, order_side, order_type, price, original_amount, status)
    VALUES (p_user_id, p_pair, p_side, 'LIMIT', v_final_price, p_amount, 'OPEN')
    RETURNING order_id INTO v_order_id;
    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql;

-- CANCEL ORDER
CREATE OR REPLACE FUNCTION sp_cancel_order(p_user_id UUID, p_order_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    v_order_status VARCHAR(20); v_order_side VARCHAR(4); v_pair VARCHAR(20);
    v_price DECIMAL; v_amount DECIMAL; v_refund_amount DECIMAL;
    v_refund_currency VARCHAR(10); v_order_owner_id UUID;
BEGIN
    SELECT status, order_side, pair, price, original_amount, user_id
    INTO v_order_status, v_order_side, v_pair, v_price, v_amount, v_order_owner_id
    FROM orders WHERE order_id = p_order_id;

    IF v_order_owner_id IS NULL OR v_order_owner_id != p_user_id THEN RAISE EXCEPTION 'Unauthorized'; END IF;
    IF v_order_status != 'OPEN' THEN RAISE EXCEPTION 'Order not open'; END IF;

    IF v_order_side = 'BUY' THEN
        v_refund_currency := split_part(v_pair, '/', 2); v_refund_amount := v_price * v_amount;
    ELSE
        v_refund_currency := split_part(v_pair, '/', 1); v_refund_amount := v_amount;
    END IF;

    UPDATE wallets SET locked_balance = locked_balance - v_refund_amount, available_balance = available_balance + v_refund_amount
    WHERE user_id = p_user_id AND currency_code = v_refund_currency;
    UPDATE orders SET status = 'CANCELLED' WHERE order_id = p_order_id;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- AUDIT LOGGER FUNCTION
CREATE OR REPLACE FUNCTION sp_log_wallet_changes()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.available_balance != NEW.available_balance OR OLD.locked_balance != NEW.locked_balance THEN
        INSERT INTO wallet_audit_logs (wallet_id, currency_code, old_balance, new_balance, old_locked, new_locked)
        VALUES (OLD.wallet_id, OLD.currency_code, OLD.available_balance, NEW.available_balance, OLD.locked_balance, NEW.locked_balance);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- MATCH ORDERS ENGINE
CREATE OR REPLACE FUNCTION sp_match_orders()
RETURNS TRIGGER AS $$
DECLARE
    v_match_order RECORD; v_trade_amount DECIMAL; v_total_cost DECIMAL;
    v_base_currency VARCHAR(10); v_quote_currency VARCHAR(10);
BEGIN
    v_base_currency := split_part(NEW.pair, '/', 1);
    v_quote_currency := split_part(NEW.pair, '/', 2);

    IF NEW.order_side = 'BUY' THEN
        SELECT * INTO v_match_order FROM orders WHERE pair = NEW.pair AND order_side = 'SELL' AND status = 'OPEN' AND price <= NEW.price ORDER BY price ASC, created_at ASC LIMIT 1;

        IF v_match_order.order_id IS NOT NULL THEN
            v_trade_amount := LEAST(NEW.original_amount, v_match_order.original_amount);
            v_total_cost := v_trade_amount * v_match_order.price;

            UPDATE wallets SET locked_balance = locked_balance - (v_trade_amount * NEW.price), available_balance = available_balance + ((NEW.price - v_match_order.price) * v_trade_amount)
            WHERE user_id = NEW.user_id AND currency_code = v_quote_currency;

            INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (NEW.user_id, v_base_currency, v_trade_amount)
            ON CONFLICT (user_id, currency_code) DO UPDATE SET available_balance = wallets.available_balance + v_trade_amount;

            UPDATE wallets SET locked_balance = locked_balance - v_trade_amount WHERE user_id = v_match_order.user_id AND currency_code = v_base_currency;
            INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (v_match_order.user_id, v_quote_currency, v_total_cost)
            ON CONFLICT (user_id, currency_code) DO UPDATE SET available_balance = wallets.available_balance + v_total_cost;

            UPDATE orders SET status = 'FILLED', filled_amount = v_trade_amount WHERE order_id = NEW.order_id;
            UPDATE orders SET status = 'FILLED', filled_amount = v_trade_amount WHERE order_id = v_match_order.order_id;

            INSERT INTO market_trades (pair, price, amount, buyer_order_id, seller_order_id)
            VALUES (NEW.pair, v_match_order.price, v_trade_amount, NEW.order_id, v_match_order.order_id);
            UPDATE market_prices SET current_price = v_match_order.price, last_updated = CURRENT_TIMESTAMP WHERE pair = NEW.pair;
            RAISE NOTICE '✅ MATCH (BUY)! Amount: %, Price: %', v_trade_amount, v_match_order.price;
        END IF;

    ELSIF NEW.order_side = 'SELL' THEN
        SELECT * INTO v_match_order FROM orders WHERE pair = NEW.pair AND order_side = 'BUY' AND status = 'OPEN' AND price >= NEW.price ORDER BY price DESC, created_at ASC LIMIT 1;

        IF v_match_order.order_id IS NOT NULL THEN
            v_trade_amount := LEAST(NEW.original_amount, v_match_order.original_amount);
            v_total_cost := v_trade_amount * v_match_order.price;

            UPDATE wallets SET locked_balance = locked_balance - v_trade_amount WHERE user_id = NEW.user_id and currency_code = v_base_currency;
            INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (NEW.user_id, v_quote_currency, v_total_cost)
            ON CONFLICT (user_id, currency_code) DO UPDATE SET available_balance = wallets.available_balance + v_total_cost;

            UPDATE wallets SET locked_balance = locked_balance - v_total_cost WHERE user_id = v_match_order.user_id AND currency_code = v_quote_currency;
            INSERT INTO wallets (user_id, currency_code, available_balance) VALUES (v_match_order.user_id, v_base_currency, v_trade_amount)
            ON CONFLICT (user_id, currency_code) DO UPDATE SET available_balance = wallets.available_balance + v_trade_amount;

            UPDATE orders SET status = 'FILLED', filled_amount = v_trade_amount WHERE order_id = NEW.order_id;
            UPDATE orders SET status = 'FILLED', filled_amount = v_trade_amount WHERE order_id = v_match_order.order_id;

            INSERT INTO market_trades (pair, price, amount, buyer_order_id, seller_order_id)
            VALUES (NEW.pair, v_match_order.price, v_trade_amount, v_match_order.order_id, NEW.order_id);
            UPDATE market_prices SET current_price = v_match_order.price, last_updated = current_timestamp WHERE pair = NEW.pair;
            RAISE NOTICE '✅ MATCH (SELL)! Amount: %, Price: %', v_trade_amount, v_match_order.price;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 2. TRIGGERS
-- ==========================================

CREATE TRIGGER trg_match_orders
AFTER INSERT ON orders
FOR EACH ROW EXECUTE FUNCTION sp_match_orders();

CREATE TRIGGER trg_audit_wallets
AFTER UPDATE ON wallets
FOR EACH ROW EXECUTE FUNCTION sp_log_wallet_changes();
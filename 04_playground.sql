DO $$
DECLARE
    v_ahmet UUID;
    v_ayse UUID;
    v_random_price DECIMAL;
    i INT;
BEGIN
    -- Kullanıcıları bul
    SELECT user_id INTO v_ahmet FROM users WHERE email = 'ahmet@sat.com';
    SELECT user_id INTO v_ayse FROM users WHERE email = 'ayse@al.com';

    -- 10 Kere Rastgele İşlem Yap
    FOR i IN 1..10 LOOP
        -- Fiyatı 95.000 ile 96.000 arasında rastgele belirle
        v_random_price := 95000 + (random() * 1000);

        -- 1. Ahmet Rastgele Fiyattan Satış Giriyor
        PERFORM sp_place_order(v_ahmet, 'BTC/USDT', 'SELL', v_random_price, 0.1);

        -- 2. Ayşe O Fiyattan Alış Giriyor (Hemen eşleşsin diye)
        PERFORM sp_place_order(v_ayse, 'BTC/USDT', 'BUY', v_random_price, 0.1);

        -- Biraz bekle (Gerçekçi zaman damgası için opsiyonel, PostgreSQL'de şart değil)
    END LOOP;

    RAISE NOTICE '✅ 10 adet rastgele işlem başarıyla tamamlandı!';
END $$;


REFRESH MATERIALIZED VIEW mv_ohlcv_1min;
SELECT * FROM mv_ohlcv_1min;
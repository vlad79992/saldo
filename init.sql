-- Дропаем старые таблицы, чтобы избежать конфликтов типов
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS charges  CASCADE;
DROP TABLE IF EXISTS saldo    CASCADE;

-- ==========================================
-- СХЕМА (Везде TIMESTAMP вместо DATE)
-- ==========================================
CREATE TABLE saldo (
    id             SERIAL PRIMARY KEY,
    account_number VARCHAR(20)   NOT NULL,
    period_date    DATE          NOT NULL,
    amount         DECIMAL(12,2) NOT NULL,
    is_base        BOOLEAN       NOT NULL DEFAULT FALSE,
    CONSTRAINT uq_saldo UNIQUE (account_number, period_date)
);

CREATE TABLE charges (
    id             SERIAL PRIMARY KEY,
    account_number VARCHAR(20)   NOT NULL,
    service_type   VARCHAR(100),
    charge_date    TIMESTAMP     NOT NULL, -- ТЕПЕРЬ С ЧАСАМИ И МИНУТАМИ
    amount         DECIMAL(12,2) NOT NULL
);

CREATE TABLE payments (
    id             SERIAL PRIMARY KEY,
    account_number VARCHAR(20)   NOT NULL,
    payment_date   TIMESTAMP     NOT NULL, -- ТЕПЕРЬ С ЧАСАМИ И МИНУТАМИ
    amount         DECIMAL(12,2) NOT NULL,
    payment_method VARCHAR(50)
);

CREATE INDEX idx_charges_acc_date  ON charges (account_number, charge_date);
CREATE INDEX idx_payments_acc_date ON payments (account_number, payment_date);

-- ==========================================
-- ТРИГГЕРЫ И ХРАНИМЫЕ ПРОЦЕДУРЫ (без изменений)
-- ==========================================
CREATE OR REPLACE FUNCTION fn_saldo_recalc_account(p_account VARCHAR)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    r RECORD; v_month_s DATE; v_ch DECIMAL(12,2); v_pay DECIMAL(12,2);
    v_prev DECIMAL(12,2) := NULL;
BEGIN
    FOR r IN SELECT id, period_date, is_base, amount
             FROM saldo WHERE account_number = p_account
             ORDER BY period_date, id
    LOOP
        IF r.is_base OR v_prev IS NULL THEN
            v_prev := r.amount;
        ELSE
            v_month_s := date_trunc('month', r.period_date)::DATE;
            SELECT COALESCE(SUM(amount),0) INTO v_ch FROM charges
             WHERE account_number = p_account
               AND charge_date >= v_month_s::TIMESTAMP
               AND charge_date <  (v_month_s + INTERVAL '1 month')::TIMESTAMP;
            SELECT COALESCE(SUM(amount),0) INTO v_pay FROM payments
             WHERE account_number = p_account
               AND payment_date >= v_month_s::TIMESTAMP
               AND payment_date <  (v_month_s + INTERVAL '1 month')::TIMESTAMP;
            v_prev := v_prev + v_ch - v_pay;
            UPDATE saldo SET amount = v_prev WHERE id = r.id;
        END IF;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION trg_saldo_recalc() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF;
    PERFORM fn_saldo_recalc_account(COALESCE(NEW.account_number, OLD.account_number));
    RETURN NULL;
END $$;

CREATE TRIGGER trg_saldo_recalc    AFTER INSERT OR UPDATE OR DELETE ON saldo FOR EACH ROW EXECUTE FUNCTION trg_saldo_recalc();
CREATE TRIGGER trg_charges_recalc  AFTER INSERT OR UPDATE OR DELETE ON charges FOR EACH ROW EXECUTE FUNCTION trg_saldo_recalc();
CREATE TRIGGER trg_payments_recalc AFTER INSERT OR UPDATE OR DELETE ON payments FOR EACH ROW EXECUTE FUNCTION trg_saldo_recalc();

CREATE OR REPLACE FUNCTION fn_report_turnover(p_year INT)
RETURNS TABLE (account_number VARCHAR(20), month_start DATE, charge_sum DECIMAL(12,2), payment_sum DECIMAL(12,2), saldo_open DECIMAL(12,2), saldo_close DECIMAL(12,2))
LANGUAGE sql STABLE AS $$
  WITH months AS (SELECT (generate_series(make_date(p_year,1,1), make_date(p_year,12,1), INTERVAL '1 month'))::DATE AS month_start),
       accounts AS (SELECT DISTINCT account_number FROM saldo)
  SELECT a.account_number, m.month_start,
    COALESCE((SELECT SUM(c.amount) FROM charges c WHERE c.account_number = a.account_number AND c.charge_date >= m.month_start::TIMESTAMP AND c.charge_date < (m.month_start + INTERVAL '1 month')::TIMESTAMP),0),
    COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.account_number = a.account_number AND p.payment_date >= m.month_start::TIMESTAMP AND p.payment_date < (m.month_start + INTERVAL '1 month')::TIMESTAMP),0),
    COALESCE((SELECT s.amount FROM saldo s WHERE s.account_number = a.account_number AND s.period_date < m.month_start ORDER BY s.period_date DESC LIMIT 1),0),
    COALESCE((SELECT s.amount FROM saldo s WHERE s.account_number = a.account_number AND s.period_date = (m.month_start + INTERVAL '1 month - 1 day')::DATE),0)
  FROM accounts a CROSS JOIN months m ORDER BY NULLIF(regexp_replace(a.account_number, '\D', '', 'g'), '')::INT NULLS LAST, a.account_number, m.month_start;
$$;

CREATE OR REPLACE FUNCTION fn_report_turnover_account(p_account VARCHAR(20), p_date_from DATE, p_date_to DATE)
RETURNS TABLE (month_start DATE, charge_sum DECIMAL(12,2), payment_sum DECIMAL(12,2), saldo_open DECIMAL(12,2), saldo_close DECIMAL(12,2))
LANGUAGE sql STABLE AS $$
  WITH months AS (SELECT (generate_series(date_trunc('month',p_date_from)::DATE, date_trunc('month',p_date_to)::DATE, INTERVAL '1 month'))::DATE AS month_start)
  SELECT m.month_start,
    COALESCE((SELECT SUM(c.amount) FROM charges c WHERE c.account_number = p_account AND c.charge_date >= m.month_start::TIMESTAMP AND c.charge_date < (m.month_start + INTERVAL '1 month')::TIMESTAMP),0),
    COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.account_number = p_account AND p.payment_date >= m.month_start::TIMESTAMP AND p.payment_date < (m.month_start + INTERVAL '1 month')::TIMESTAMP),0),
    COALESCE((SELECT s.amount FROM saldo s WHERE s.account_number = p_account AND s.period_date < m.month_start ORDER BY s.period_date DESC LIMIT 1),0),
    COALESCE((SELECT s.amount FROM saldo s WHERE s.account_number = p_account AND s.period_date = (m.month_start + INTERVAL '1 month - 1 day')::DATE),0)
  FROM months m
  UNION ALL
  SELECT NULL,
    COALESCE((SELECT SUM(c.amount) FROM charges c WHERE c.account_number = p_account AND c.charge_date >= p_date_from::TIMESTAMP AND c.charge_date < (p_date_to + INTERVAL '1 day')::TIMESTAMP),0),
    COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.account_number = p_account AND p.payment_date >= p_date_from::TIMESTAMP AND p.payment_date < (p_date_to + INTERVAL '1 day')::TIMESTAMP),0),
    COALESCE((SELECT s.amount FROM saldo s WHERE s.account_number = p_account AND s.period_date < date_trunc('month',p_date_from)::DATE ORDER BY s.period_date DESC LIMIT 1),0),
    COALESCE((SELECT s.amount FROM saldo s WHERE s.account_number = p_account AND s.period_date <= p_date_to ORDER BY s.period_date DESC LIMIT 1),0)
  ORDER BY month_start NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION fn_report_debtors(p_as_of DATE)
RETURNS TABLE (account_number VARCHAR(20), last_charge DECIMAL(12,2), saldo_debt DECIMAL(12,2), debt_1 DECIMAL(12,2), debt_2 DECIMAL(12,2), debt_3 DECIMAL(12,2), debt_over3 DECIMAL(12,2))
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_acc VARCHAR(20);
  v_debt DECIMAL(12,2);
  v_rem DECIMAL(12,2);
  v_last_charge DECIMAL(12,2);
  v_k INT;
  v_month DATE;
  v_ch DECIMAL(12,2);
  v_span INT;
  v_base_d DATE;
  v_base_a DECIMAL(12,2);
  d1 DECIMAL(12,2); d2 DECIMAL(12,2); d3 DECIMAL(12,2); d4 DECIMAL(12,2);
BEGIN
  FOR v_acc IN
    SELECT s.account_number
    FROM saldo s
    GROUP BY s.account_number
    ORDER BY NULLIF(regexp_replace(s.account_number, '\D', '', 'g'), '')::INT NULLS LAST, s.account_number
  LOOP
    SELECT s2.amount INTO v_debt
    FROM saldo s2
    WHERE s2.account_number = v_acc AND s2.period_date <= p_as_of
    ORDER BY s2.period_date DESC LIMIT 1;
    v_debt := COALESCE(v_debt, 0);

    IF v_debt > 0 THEN
      SELECT COALESCE(SUM(c.amount), 0) INTO v_last_charge
      FROM charges c
      WHERE c.account_number = v_acc
        AND c.charge_date >= (date_trunc('month', p_as_of) - INTERVAL '1 month')::TIMESTAMP
        AND c.charge_date < date_trunc('month', p_as_of)::TIMESTAMP;

      SELECT s3.period_date, s3.amount INTO v_base_d, v_base_a
      FROM saldo s3
      WHERE s3.account_number = v_acc
      ORDER BY s3.period_date LIMIT 1;

      v_rem := v_debt; v_span := 999;
      FOR v_k IN 1..1200 LOOP
        v_month := (date_trunc('month', p_as_of) - v_k * INTERVAL '1 month')::DATE;
        SELECT COALESCE(SUM(c2.amount), 0) INTO v_ch
        FROM charges c2
        WHERE c2.account_number = v_acc
          AND c2.charge_date >= v_month::TIMESTAMP
          AND c2.charge_date < (v_month + INTERVAL '1 month')::TIMESTAMP;
        IF v_base_d IS NOT NULL AND v_month = date_trunc('month', v_base_d)::DATE THEN
          v_ch := v_ch + v_base_a;
        END IF;
        IF v_ch <> 0 THEN
          v_span := v_k;
          v_rem := v_rem - v_ch;
          IF v_rem <= 0 THEN EXIT; END IF;
        END IF;
        IF v_base_d IS NOT NULL AND v_month <= date_trunc('month', v_base_d)::DATE THEN EXIT; END IF;
      END LOOP;
      IF v_rem > 0 THEN v_span := 999; END IF;

      d1 := 0; d2 := 0; d3 := 0; d4 := 0;
      CASE
        WHEN v_span = 1 THEN d1 := v_debt;
        WHEN v_span = 2 THEN d2 := v_debt;
        WHEN v_span = 3 THEN d3 := v_debt;
        ELSE d4 := v_debt;
      END CASE;

      account_number := v_acc;
      saldo_debt := v_debt;
      debt_1 := d1; debt_2 := d2; debt_3 := d3; debt_over3 := d4;
      last_charge := v_last_charge;
      RETURN NEXT;
    END IF;
  END LOOP;
END $$;

-- ==========================================
-- ДАННЫЕ (Обратите внимание на формат времени: 'YYYY-MM-DD HH:MM:SS')
-- ==========================================
INSERT INTO saldo (account_number, period_date, amount, is_base) VALUES
('1', '2016-12-31', 5379.37, TRUE), ('1', '2017-01-31', 0, FALSE), ('1', '2017-02-28', 0, FALSE), ('1', '2017-03-31', 0, FALSE), ('1', '2017-04-30', 0, FALSE), ('1', '2017-05-31', 0, FALSE), ('1', '2017-06-30', 0, FALSE), ('1', '2017-07-31', 0, FALSE), ('1', '2017-08-31', 0, FALSE), ('1', '2017-09-30', 0, FALSE), ('1', '2017-10-31', 0, FALSE),
('2', '2016-12-31', 14476.86, TRUE), ('2', '2017-01-31', 0, FALSE), ('2', '2017-02-28', 0, FALSE), ('2', '2017-03-31', 0, FALSE), ('2', '2017-04-30', 0, FALSE), ('2', '2017-05-31', 0, FALSE), ('2', '2017-06-30', 0, FALSE), ('2', '2017-07-31', 0, FALSE), ('2', '2017-08-31', 0, FALSE), ('2', '2017-09-30', 0, FALSE), ('2', '2017-10-31', 0, FALSE),
('3', '2016-12-31', 3591.62, TRUE), ('3', '2017-01-31', 0, FALSE), ('3', '2017-02-28', 0, FALSE), ('3', '2017-03-31', 0, FALSE), ('3', '2017-04-30', 0, FALSE), ('3', '2017-05-31', 0, FALSE), ('3', '2017-06-30', 0, FALSE), ('3', '2017-07-31', 0, FALSE), ('3', '2017-08-31', 0, FALSE), ('3', '2017-09-30', 0, FALSE), ('3', '2017-10-31', 0, FALSE),
('4', '2016-12-31', 8543.02, TRUE), ('4', '2017-01-31', 0, FALSE), ('4', '2017-02-28', 0, FALSE), ('4', '2017-03-31', 0, FALSE), ('4', '2017-04-30', 0, FALSE), ('4', '2017-05-31', 0, FALSE), ('4', '2017-06-30', 0, FALSE), ('4', '2017-07-31', 0, FALSE), ('4', '2017-08-31', 0, FALSE), ('4', '2017-09-30', 0, FALSE), ('4', '2017-10-31', 0, FALSE),
('5', '2016-12-31', 3107.40, TRUE), ('5', '2017-01-31', 0, FALSE), ('5', '2017-02-28', 0, FALSE), ('5', '2017-03-31', 0, FALSE), ('5', '2017-04-30', 0, FALSE), ('5', '2017-05-31', 0, FALSE), ('5', '2017-06-30', 0, FALSE), ('5', '2017-07-31', 0, FALSE), ('5', '2017-08-31', 0, FALSE), ('5', '2017-09-30', 0, FALSE), ('5', '2017-10-31', 0, FALSE),
('6', '2016-12-31', -510.53, TRUE), ('6', '2017-01-31', 0, FALSE), ('6', '2017-02-28', 0, FALSE), ('6', '2017-03-31', 0, FALSE), ('6', '2017-04-30', 0, FALSE), ('6', '2017-05-31', 0, FALSE), ('6', '2017-06-30', 0, FALSE), ('6', '2017-07-31', 0, FALSE), ('6', '2017-08-31', 0, FALSE), ('6', '2017-09-30', 0, FALSE), ('6', '2017-10-31', 0, FALSE),
('12', '2016-12-31', 25000.00, TRUE), ('12', '2017-01-31', 0, FALSE), ('12', '2017-02-28', 0, FALSE), ('12', '2017-03-31', 0, FALSE), ('12', '2017-04-30', 0, FALSE), ('12', '2017-05-31', 0, FALSE), ('12', '2017-06-30', 0, FALSE), ('12', '2017-07-31', 0, FALSE), ('12', '2017-08-31', 0, FALSE), ('12', '2017-09-30', 0, FALSE),
('14', '2016-12-31', 2000.00, TRUE), ('14', '2017-01-31', 0, FALSE), ('14', '2017-02-28', 0, FALSE), ('14', '2017-03-31', 0, FALSE), ('14', '2017-04-30', 0, FALSE), ('14', '2017-05-31', 0, FALSE), ('14', '2017-06-30', 0, FALSE), ('14', '2017-07-31', 0, FALSE), ('14', '2017-08-31', 0, FALSE), ('14', '2017-09-30', 0, FALSE);

INSERT INTO charges (account_number, service_type, charge_date, amount) VALUES
('1', 'ЖКУ', '2017-01-15 09:00:00', 4590.22), ('1', 'ЖКУ', '2017-02-15 09:00:00', 4589.64), ('1', 'ЖКУ', '2017-03-15 09:00:00', 5030.62), ('1', 'ЖКУ', '2017-04-15 09:00:00', 4502.41), ('1', 'ЖКУ', '2017-05-15 09:00:00', 4405.16), ('1', 'ЖКУ', '2017-06-15 09:00:00', 4030.90), ('1', 'ЖКУ', '2017-07-15 09:00:00', 4528.61), ('1', 'ЖКУ', '2017-08-15 09:00:00', 4579.44), ('1', 'ЖКУ', '2017-09-15 09:00:00', 4851.68), ('1', 'ЖКУ', '2017-10-15 09:00:00', 4823.83),
('2', 'ЖКУ', '2017-01-15 09:00:00', 4870.26), ('2', 'ЖКУ', '2017-02-15 09:00:00', 4880.88), ('2', 'ЖКУ', '2017-03-15 09:00:00', 6522.06), ('2', 'ЖКУ', '2017-04-15 09:00:00', 5095.99), ('2', 'ЖКУ', '2017-05-15 09:00:00', 4829.47), ('2', 'ЖКУ', '2017-06-15 09:00:00', 4137.06), ('2', 'ЖКУ', '2017-07-15 09:00:00', 4988.47), ('2', 'ЖКУ', '2017-08-15 09:00:00', 4788.85), ('2', 'ЖКУ', '2017-09-15 09:00:00', 5082.79), ('2', 'ЖКУ', '2017-10-15 09:00:00', 5111.77),
('3', 'ЖКУ', '2017-01-15 09:00:00', 2430.33), ('3', 'ЖКУ', '2017-02-15 09:00:00', 3120.22), ('3', 'ЖКУ', '2017-03-15 09:00:00', 3497.19), ('3', 'ЖКУ', '2017-04-15 09:00:00', 2051.45), ('3', 'ЖКУ', '2017-05-15 09:00:00', 2988.59), ('3', 'ЖКУ', '2017-06-15 09:00:00', 2593.99), ('3', 'ЖКУ', '2017-07-15 09:00:00', 3114.73), ('3', 'ЖКУ', '2017-08-15 09:00:00', 3114.73), ('3', 'ЖКУ', '2017-09-15 09:00:00', 2753.53), ('3', 'ЖКУ', '2017-10-15 09:00:00', 3330.68),
('4', 'ЖКУ', '2017-01-15 09:00:00', 4633.43), ('4', 'ЖКУ', '2017-02-15 09:00:00', 6002.58), ('4', 'ЖКУ', '2017-03-15 09:00:00', 6756.52), ('4', 'ЖКУ', '2017-04-15 09:00:00', 3916.04), ('4', 'ЖКУ', '2017-05-15 09:00:00', 5790.33), ('4', 'ЖКУ', '2017-06-15 09:00:00', 5001.12), ('4', 'ЖКУ', '2017-07-15 09:00:00', 5977.39), ('4', 'ЖКУ', '2017-08-15 09:00:00', 5977.39), ('4', 'ЖКУ', '2017-09-15 09:00:00', 5254.99), ('4', 'ЖКУ', '2017-10-15 09:00:00', 6409.30),
('5', 'ЖКУ', '2017-01-15 09:00:00', 5961.25), ('5', 'ЖКУ', '2017-02-15 09:00:00', 5971.87), ('5', 'ЖКУ', '2017-03-15 09:00:00', 7047.40), ('5', 'ЖКУ', '2017-04-15 09:00:00', 6018.74), ('5', 'ЖКУ', '2017-05-15 09:00:00', 4257.83), ('5', 'ЖКУ', '2017-06-15 09:00:00', 3923.09), ('5', 'ЖКУ', '2017-07-15 09:00:00', 5629.70), ('5', 'ЖКУ', '2017-08-15 09:00:00', 5670.83), ('5', 'ЖКУ', '2017-09-15 09:00:00', 6006.69), ('5', 'ЖКУ', '2017-10-15 09:00:00', 4424.71),
('6', 'ЖКУ', '2017-01-15 09:00:00', 4204.64), ('6', 'ЖКУ', '2017-02-15 09:00:00', 4215.26), ('6', 'ЖКУ', '2017-03-15 09:00:00', 5400.51), ('6', 'ЖКУ', '2017-04-15 09:00:00', 4450.48), ('6', 'ЖКУ', '2017-05-15 09:00:00', 4180.72), ('6', 'ЖКУ', '2017-06-15 09:00:00', 3909.60), ('6', 'ЖКУ', '2017-07-15 09:00:00', 4057.27), ('6', 'ЖКУ', '2017-08-15 09:00:00', 4481.84), ('6', 'ЖКУ', '2017-09-15 09:00:00', 4739.99), ('6', 'ЖКУ', '2017-10-15 09:00:00', 4466.83),
('12', 'ЖКУ', '2017-01-15 09:00:00', 2500.00), ('12', 'ЖКУ', '2017-02-15 09:00:00', 2300.00), ('12', 'ЖКУ', '2017-03-15 09:00:00', 1400.00), ('12', 'ЖКУ', '2017-04-15 09:00:00', 900.00), ('12', 'ЖКУ', '2017-05-15 09:00:00', 700.00), ('12', 'ЖКУ', '2017-06-15 09:00:00', 300.00), ('12', 'ЖКУ', '2017-07-15 09:00:00', 150.00), ('12', 'ЖКУ', '2017-08-15 09:00:00', 100.00), ('12', 'ЖКУ', '2017-09-15 09:00:00', 109.75),
('14', 'ЖКУ', '2017-01-15 09:00:00', 1500.00), ('14', 'ЖКУ', '2017-02-15 09:00:00', 700.00), ('14', 'ЖКУ', '2017-03-15 09:00:00', 600.00), ('14', 'ЖКУ', '2017-04-15 09:00:00', 300.00), ('14', 'ЖКУ', '2017-05-15 09:00:00', 100.00), ('14', 'ЖКУ', '2017-06-15 09:00:00', 50.00), ('14', 'ЖКУ', '2017-07-15 09:00:00', 20.00), ('14', 'ЖКУ', '2017-08-15 09:00:00', 10.00), ('14', 'ЖКУ', '2017-09-15 09:00:00', 10.26);

INSERT INTO payments (account_number, payment_date, amount, payment_method) VALUES
('1', '2017-01-20 14:23:11', 4004.06, 'Банк'), ('1', '2017-02-20 10:05:42', 4004.06, 'Банк'), ('1', '2017-03-20 16:48:09', 586.16, 'Банк'), ('1', '2017-04-20 09:12:33', 6405.35, 'Банк'), ('1', '2017-05-20 13:57:21', 3127.10, 'Банк'), ('1', '2017-06-20 11:44:55', 4405.16, 'Банк'), ('1', '2017-07-20 15:30:08', 4030.90, 'Банк'), ('1', '2017-08-20 12:22:47', 4528.61, 'Банк'), ('1', '2017-09-20 14:15:39', 4579.44, 'Банк'), ('1', '2017-10-20 09:48:26', 4851.68, 'Банк'),
('2', '2017-01-20 11:00:00', 0.00, 'Банк'), ('2', '2017-02-20 15:12:30', 4345.70, 'Банк'), ('2', '2017-03-20 10:45:22', 9892.23, 'Банк'), ('2', '2017-04-20 09:00:00', 0.00, 'Банк'), ('2', '2017-05-20 14:33:18', 5095.99, 'Банк'), ('2', '2017-06-20 16:20:09', 19306.33, 'Банк'), ('2', '2017-07-20 13:08:44', 5000.00, 'Банк'), ('2', '2017-08-20 11:55:37', 6160.80, 'Банк'), ('2', '2017-09-20 15:40:12', 4788.85, 'Банк'), ('2', '2017-10-20 09:27:56', 5082.79, 'Банк'),
('3', '2017-01-20 08:15:30', 0.00, 'Банк'), ('3', '2017-02-20 12:40:18', 6000.00, 'Банк'), ('3', '2017-03-20 17:25:44', 0.00, 'Банк'), ('3', '2017-04-20 10:05:52', 6200.00, 'Банк'), ('3', '2017-05-20 14:30:09', 0.00, 'Банк'), ('3', '2017-06-20 11:50:37', 8000.00, 'Банк'), ('3', '2017-07-20 15:15:22', 0.00, 'Банк'), ('3', '2017-08-20 09:40:11', 6400.00, 'Банк'), ('3', '2017-09-20 13:25:55', 0.00, 'Банк'), ('3', '2017-10-20 16:10:08', 6000.00, 'Банк'),
('4', '2017-01-20 10:30:00', 0.00, 'Банк'), ('4', '2017-02-20 14:15:22', 11123.00, 'Банк'), ('4', '2017-03-20 09:50:48', 442.00, 'Банк'), ('4', '2017-04-20 16:25:33', 12956.00, 'Банк'), ('4', '2017-05-20 11:00:00', 0.00, 'Банк'), ('4', '2017-06-20 13:40:19', 9706.37, 'Банк'), ('4', '2017-07-20 15:55:07', 5001.12, 'Банк'), ('4', '2017-08-20 10:20:45', 7391.94, 'Банк'), ('4', '2017-09-20 08:10:30', 0.00, 'Банк'), ('4', '2017-10-20 17:35:18', 11232.38, 'Банк'),
('5', '2017-01-20 12:05:33', 10170.50, 'Банк'), ('5', '2017-02-20 09:00:00', 0.00, 'Банк'), ('5', '2017-03-20 14:30:00', 0.00, 'Банк'), ('5', '2017-04-20 16:45:28', 11917.42, 'Банк'), ('5', '2017-05-20 11:20:00', 0.00, 'Банк'), ('5', '2017-06-20 13:00:00', 0.00, 'Банк'), ('5', '2017-07-20 15:30:00', 0.00, 'Банк'), ('5', '2017-08-20 10:10:42', 9552.79, 'Банк'), ('5', '2017-09-20 08:55:17', 5670.83, 'Банк'), ('5', '2017-10-20 17:25:09', 6006.69, 'Банк'),
('6', '2017-01-20 10:00:00', 4000.00, 'Банк'), ('6', '2017-02-20 10:00:00', 4000.00, 'Банк'), ('6', '2017-03-20 10:00:00', 4000.00, 'Банк'), ('6', '2017-04-20 10:00:00', 4300.00, 'Банк'), ('6', '2017-05-20 10:00:00', 5300.00, 'Банк'), ('6', '2017-06-20 10:00:00', 4600.00, 'Банк'), ('6', '2017-07-20 10:00:00', 4500.00, 'Банк'), ('6', '2017-08-20 10:00:00', 4500.00, 'Банк'), ('6', '2017-09-20 10:00:00', 4000.00, 'Банк'), ('6', '2017-10-20 10:00:00', 4000.00, 'Банк'),
('12', '2017-01-20 12:00:00', 0.00, 'Банк'), ('12', '2017-02-20 12:00:00', 0.00, 'Банк'), ('12', '2017-03-20 12:00:00', 0.00, 'Банк'), ('12', '2017-04-20 12:00:00', 0.00, 'Банк'), ('12', '2017-05-20 12:00:00', 0.00, 'Банк'), ('12', '2017-06-20 12:00:00', 0.00, 'Банк'), ('12', '2017-07-20 12:00:00', 0.00, 'Банк'), ('12', '2017-08-20 12:00:00', 0.00, 'Банк'), ('12', '2017-09-20 12:00:00', 0.00, 'Банк'),
('14', '2017-01-20 12:00:00', 0.00, 'Банк'), ('14', '2017-02-20 12:00:00', 0.00, 'Банк'), ('14', '2017-03-20 12:00:00', 0.00, 'Банк'), ('14', '2017-04-20 12:00:00', 0.00, 'Банк'), ('14', '2017-05-20 12:00:00', 0.00, 'Банк'), ('14', '2017-06-20 12:00:00', 0.00, 'Банк'), ('14', '2017-07-20 12:00:00', 0.00, 'Банк'), ('14', '2017-08-20 12:00:00', 0.00, 'Банк'), ('14', '2017-09-20 12:00:00', 0.00, 'Банк');

SELECT fn_saldo_recalc_account(account_number) FROM (SELECT DISTINCT account_number FROM saldo) t;

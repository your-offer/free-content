-- Выполните dataset.sql в том же соединении перед этими запросами.
-- Во всех задачах: начало периода включено, конец исключён.

-- Q1: дедупликация событий. Последняя загрузка побеждает.
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY event_id ORDER BY ingested_at DESC, ingest_id DESC
    ) AS rn
    FROM pa_events_raw
)
SELECT event_id, user_id, event_name, event_at
FROM ranked WHERE rn = 1
ORDER BY event_id;

-- Q2: оплаченные заказы каждого пользователя, включая нули.
-- Статус и период стоят в ON, чтобы LEFT JOIN сохранил всех пользователей.
SELECT u.user_id, COUNT(o.order_id) AS paid_orders,
       COALESCE(SUM(o.amount), 0) AS revenue
FROM pa_users u
LEFT JOIN pa_orders o ON o.user_id = u.user_id
    AND o.status = 'paid'
    AND o.paid_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
    AND o.paid_at < TIMESTAMPTZ '2026-11-05 00:00+00'
GROUP BY u.user_id
ORDER BY u.user_id;

-- Q3: top-2 уровня выручки пользователей с сохранением всех равных мест.
WITH revenue AS (
    SELECT user_id, SUM(amount) AS revenue
    FROM pa_orders
    WHERE status = 'paid'
      AND paid_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND paid_at < TIMESTAMPTZ '2026-11-05 00:00+00'
    GROUP BY user_id
), ranked AS (
    SELECT *, DENSE_RANK() OVER (ORDER BY revenue DESC) AS revenue_rank
    FROM revenue
)
SELECT * FROM ranked WHERE revenue_rank <= 2
ORDER BY revenue_rank, user_id;

-- Q4: выручка, средний чек, ARPPU и ARPU активных пользователей.
-- Источник денег — pa_orders, а не события интерфейса purchase.
WITH active AS (
    SELECT DISTINCT user_id
    FROM pa_events_raw
    WHERE user_id IS NOT NULL
      AND event_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND event_at < TIMESTAMPTZ '2026-11-05 00:00+00'
), financials AS (
    SELECT COALESCE(SUM(amount), 0) AS revenue,
           COUNT(*) AS paid_orders, COUNT(DISTINCT user_id) AS paying_users
    FROM pa_orders
    WHERE status = 'paid'
      AND paid_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND paid_at < TIMESTAMPTZ '2026-11-05 00:00+00'
), active_revenue AS (
    SELECT COALESCE(SUM(o.amount), 0) AS revenue
    FROM pa_orders o JOIN active a ON a.user_id = o.user_id
    WHERE o.status = 'paid'
      AND o.paid_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND o.paid_at < TIMESTAMPTZ '2026-11-05 00:00+00'
)
SELECT f.revenue, f.paid_orders, f.paying_users,
       (SELECT COUNT(*) FROM active) AS active_users,
       ROUND(f.revenue / NULLIF(f.paid_orders, 0), 2) AS average_order_value,
       ROUND(f.revenue / NULLIF(f.paying_users, 0), 2) AS arppu,
       ROUND(ar.revenue / NULLIF((SELECT COUNT(*) FROM active), 0), 2) AS arpu_active
FROM financials f CROSS JOIN active_revenue ar;

-- Q5: календарный D1 retention по дате регистрации в UTC.
-- Данные наблюдаем до 2026-11-05 00:00 UTC, не включая границу.
-- Когорты, у которых D1 ещё не закончился, исключаем, а не считаем нулевыми.
WITH cohorts AS (
    SELECT user_id, (registered_at AT TIME ZONE 'UTC')::date AS cohort_date
    FROM pa_users
    WHERE registered_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND registered_at < TIMESTAMPTZ '2026-11-04 00:00+00'
), activity AS (
    SELECT DISTINCT user_id, (event_at AT TIME ZONE 'UTC')::date AS activity_date
    FROM pa_events_raw
    WHERE user_id IS NOT NULL
      AND event_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND event_at < TIMESTAMPTZ '2026-11-05 00:00+00'
)
SELECT c.cohort_date, COUNT(*) AS cohort_size,
       COUNT(a.user_id) AS returned_d1,
       ROUND(100.0 * COUNT(a.user_id) / NULLIF(COUNT(*), 0), 2) AS retention_d1_pct
FROM cohorts c
LEFT JOIN activity a ON a.user_id = c.user_id AND a.activity_date = c.cohort_date + 1
GROUP BY c.cohort_date ORDER BY c.cohort_date;

-- Q6: view -> checkout -> purchase, строго по времени в одном UTC-дне.
-- Пользователь считается один раз на шаг за весь период.
-- checkout до view и purchase на следующий день цепочку не продолжают.
WITH e AS (
    SELECT DISTINCT user_id, event_name, event_at,
           (event_at AT TIME ZONE 'UTC')::date AS event_date
    FROM pa_events_raw
    WHERE user_id IS NOT NULL
      AND event_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND event_at < TIMESTAMPTZ '2026-11-05 00:00+00'
), views AS (
    SELECT user_id, event_date, MIN(event_at) AS view_at
    FROM e WHERE event_name = 'view'
    GROUP BY user_id, event_date
), checkouts AS (
    SELECT v.user_id, v.event_date, v.view_at, MIN(e.event_at) AS checkout_at
    FROM views v LEFT JOIN e ON e.user_id = v.user_id
        AND e.event_date = v.event_date AND e.event_name = 'checkout'
        AND e.event_at > v.view_at
    GROUP BY v.user_id, v.event_date, v.view_at
), purchases AS (
    SELECT c.user_id, c.event_date, c.checkout_at, MIN(e.event_at) AS purchase_at
    FROM checkouts c LEFT JOIN e ON e.user_id = c.user_id
        AND e.event_date = c.event_date AND e.event_name = 'purchase'
        AND e.event_at > c.checkout_at
    GROUP BY c.user_id, c.event_date, c.checkout_at
)
SELECT COUNT(DISTINCT user_id) AS viewed,
       COUNT(DISTINCT user_id) FILTER (WHERE checkout_at IS NOT NULL) AS checked_out,
       COUNT(DISTINCT user_id) FILTER (WHERE purchase_at IS NOT NULL) AS purchased,
       ROUND(100.0 * COUNT(DISTINCT user_id) FILTER (WHERE purchase_at IS NOT NULL)
           / NULLIF(COUNT(DISTINCT user_id), 0), 2) AS conversion_pct
FROM purchases;

-- Q7: ноябрьская выручка: UTC и Europe/Moscow имеют разные границы.
SELECT
    COALESCE(SUM(amount) FILTER (
        WHERE paid_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
          AND paid_at < TIMESTAMPTZ '2026-12-01 00:00+00'
    ), 0) AS revenue_nov_utc,
    COALESCE(SUM(amount) FILTER (
        WHERE paid_at >= TIMESTAMP '2026-11-01 00:00' AT TIME ZONE 'Europe/Moscow'
          AND paid_at < TIMESTAMP '2026-12-01 00:00' AT TIME ZONE 'Europe/Moscow'
    ), 0) AS revenue_nov_moscow
FROM pa_orders WHERE status = 'paid';

-- Q8: непрерывный календарь, накопительная выручка, среднее за 3 дня.
-- Первые два окна неполные: делим на фактическое число доступных дней.
WITH days AS (
    SELECT DATE '2026-11-01' + n AS day
    FROM generate_series(0, 3) AS g(n)
), daily AS (
    SELECT (paid_at AT TIME ZONE 'UTC')::date AS day, SUM(amount) AS revenue
    FROM pa_orders
    WHERE status = 'paid'
      AND paid_at >= TIMESTAMPTZ '2026-11-01 00:00+00'
      AND paid_at < TIMESTAMPTZ '2026-11-05 00:00+00'
    GROUP BY 1
), calendar AS (
    SELECT d.day, COALESCE(p.revenue, 0) AS revenue
    FROM days d LEFT JOIN daily p USING (day)
)
SELECT day, revenue,
       SUM(revenue) OVER (ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           AS cumulative_revenue,
       ROUND(AVG(revenue) OVER (ORDER BY day ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
           AS rolling_3_days
FROM calendar ORDER BY day;

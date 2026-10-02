use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::Response,
    routing::{delete, get, post, put},
};
use chrono::{NaiveDate, NaiveDateTime};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, PgPool, postgres::PgPoolOptions};
use std::env;
use tower_http::services::ServeDir;

// ==========================================
// СЕРИАЛИЗАЦИЯ ДАТЫ+ВРЕМЕНИ (с секундами)
// ==========================================
mod ts_serde {
    use chrono::NaiveDateTime;
    use serde::{Deserialize, Deserializer, Serializer};
    const FORMATS: [&str; 5] = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d",
    ];
    pub fn serialize<S: Serializer>(v: &NaiveDateTime, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&v.format("%Y-%m-%d %H:%M:%S").to_string())
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<NaiveDateTime, D::Error> {
        let raw = String::deserialize(d)?;
        for f in FORMATS {
            if let Ok(v) = NaiveDateTime::parse_from_str(raw.trim(), f) {
                return Ok(v);
            }
        }
        Err(serde::de::Error::custom(format!(
            "Неверный формат даты/времени: {raw}"
        )))
    }
}

// ==========================================
// СТРУКТУРЫ ДАННЫХ
// ==========================================
#[derive(FromRow, Serialize, Deserialize, Clone, Debug)]
struct SaldoRecord {
    id: i32,
    account_number: String,
    period_date: NaiveDate,
    amount: Decimal,
    is_base: bool,
}

#[derive(Deserialize)]
struct SaldoRequest {
    account_number: String,
    period_date: NaiveDate,
    amount: Decimal,
    #[serde(default)]
    is_base: bool,
}

#[derive(FromRow, Serialize, Deserialize, Clone, Debug)]
struct ChargeRecord {
    id: i32,
    account_number: String,
    service_type: Option<String>,
    #[serde(with = "ts_serde")]
    charge_date: NaiveDateTime,
    amount: Decimal,
}

#[derive(Deserialize)]
struct ChargeRequest {
    account_number: String,
    service_type: Option<String>,
    #[serde(with = "ts_serde")]
    charge_date: NaiveDateTime,
    amount: Decimal,
}

#[derive(FromRow, Serialize, Deserialize, Clone, Debug)]
struct PaymentRecord {
    id: i32,
    account_number: String,
    #[serde(with = "ts_serde")]
    payment_date: NaiveDateTime,
    amount: Decimal,
    payment_method: Option<String>,
}

#[derive(Deserialize)]
struct PaymentRequest {
    account_number: String,
    #[serde(with = "ts_serde")]
    payment_date: NaiveDateTime,
    amount: Decimal,
    payment_method: Option<String>,
}

// ==========================================
// СТРУКТУРЫ ОТЧЕТОВ
// ==========================================
#[derive(FromRow, Serialize)]
struct TurnoverRow {
    account_number: String,
    month_start: NaiveDate,
    charge_sum: Decimal,
    payment_sum: Decimal,
    saldo_open: Decimal,
    saldo_close: Decimal,
}

#[derive(FromRow, Serialize)]
struct TurnoverAccountRow {
    month_start: Option<NaiveDate>,
    charge_sum: Decimal,
    payment_sum: Decimal,
    saldo_open: Decimal,
    saldo_close: Decimal,
}

#[derive(FromRow, Serialize)]
struct DebtorRow {
    account_number: String,
    last_charge: Decimal,
    saldo_debt: Decimal,
    debt_1: Decimal,
    debt_2: Decimal,
    debt_3: Decimal,
    debt_over3: Decimal,
}

#[derive(Deserialize)]
struct YearQuery {
    year: i32,
}

#[derive(Deserialize)]
struct RangeQuery {
    from: NaiveDate,
    to: NaiveDate,
}

#[derive(Deserialize)]
struct AsOfQuery {
    as_of: NaiveDate,
}

// ==========================================
// MIDDLEWARE
// ==========================================
// Хэшированные ассеты — только те, что в /assets/ или содержат хэш в имени (main.abc123.js)
fn is_hashed_asset(path: &str) -> bool {
    path.starts_with("/assets/")
        || (path.contains('.') && {
            let name = path.rsplit('/').next().unwrap_or("");
            let stem = name.split('.').nth(0).unwrap_or("");
            let hash = name.split('.').nth(1).unwrap_or("");
            hash.len() >= 8 && hash.chars().all(|c| c.is_ascii_hexdigit()) && !stem.is_empty()
        })
}
const IMMUTABLE: &str = "public, max-age=31536000, immutable";
const NO_CACHE: &str = "no-cache, no-store, must-revalidate";

async fn cache_control_middleware(req: axum::extract::Request, next: Next) -> Response {
    let path = req.uri().path().to_string();
    let mut resp = next.run(req).await;
    if is_hashed_asset(&path) {
        resp.headers_mut()
            .insert(header::CACHE_CONTROL, HeaderValue::from_static(IMMUTABLE));
    } else {
        resp.headers_mut()
            .insert(header::CACHE_CONTROL, HeaderValue::from_static(NO_CACHE));
    }
    resp
}

// ==========================================
// ОБРАБОТЧИКИ: SALDO
// ==========================================
async fn get_all_saldos(
    State(pool): State<PgPool>,
) -> Result<Json<Vec<SaldoRecord>>, (StatusCode, String)> {
    sqlx::query_as::<_, SaldoRecord>(
        "SELECT * FROM saldo ORDER BY NULLIF(regexp_replace(account_number, '\\D', '', 'g'), '')::INT NULLS LAST, account_number, period_date")
        .fetch_all(&pool).await.map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

async fn get_saldo_by_id(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
) -> Result<Json<SaldoRecord>, (StatusCode, String)> {
    sqlx::query_as::<_, SaldoRecord>("SELECT * FROM saldo WHERE id = $1")
        .bind(id)
        .fetch_optional(&pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Запись не найдена".to_string()))
}

async fn create_saldo(
    State(pool): State<PgPool>,
    Json(p): Json<SaldoRequest>,
) -> Result<(StatusCode, Json<SaldoRecord>), (StatusCode, String)> {
    let rec = sqlx::query_as::<_, SaldoRecord>(
        "INSERT INTO saldo (account_number, period_date, amount, is_base) VALUES ($1,$2,$3,$4) RETURNING *")
        .bind(&p.account_number).bind(p.period_date).bind(p.amount).bind(p.is_base)
        .fetch_one(&pool).await
        .map_err(|e| {
            if let Some(db) = e.as_database_error() {
                if db.code().as_deref() == Some("23505") {
                    return (StatusCode::CONFLICT, "Запись для этого счета и периода уже существует".into());
                }
            }
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;
    Ok((StatusCode::CREATED, Json(rec)))
}

async fn update_saldo(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
    Json(p): Json<SaldoRequest>,
) -> Result<Json<SaldoRecord>, (StatusCode, String)> {
    sqlx::query_as::<_, SaldoRecord>(
        "UPDATE saldo SET account_number=$1, period_date=$2, amount=$3, is_base=$4 WHERE id=$5 RETURNING *")
        .bind(&p.account_number).bind(p.period_date).bind(p.amount).bind(p.is_base).bind(id)
        .fetch_optional(&pool).await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json).ok_or_else(|| (StatusCode::NOT_FOUND, "Запись не найдена".to_string()))
}

async fn delete_saldo(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
) -> Result<StatusCode, (StatusCode, String)> {
    let r = sqlx::query("DELETE FROM saldo WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    if r.rows_affected() == 0 {
        Err((StatusCode::NOT_FOUND, "Запись не найдена".into()))
    } else {
        Ok(StatusCode::NO_CONTENT)
    }
}

// ==========================================
// ОБРАБОТЧИКИ: CHARGES
// ==========================================
async fn get_all_charges(
    State(pool): State<PgPool>,
) -> Result<Json<Vec<ChargeRecord>>, (StatusCode, String)> {
    sqlx::query_as::<_, ChargeRecord>(
        "SELECT * FROM charges ORDER BY NULLIF(regexp_replace(account_number, '\\D', '', 'g'), '')::INT NULLS LAST, account_number, charge_date")
        .fetch_all(&pool).await.map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

async fn get_charge_by_id(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
) -> Result<Json<ChargeRecord>, (StatusCode, String)> {
    sqlx::query_as::<_, ChargeRecord>("SELECT * FROM charges WHERE id = $1")
        .bind(id)
        .fetch_optional(&pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Запись не найдена".to_string()))
}

async fn create_charge(
    State(pool): State<PgPool>,
    Json(p): Json<ChargeRequest>,
) -> Result<(StatusCode, Json<ChargeRecord>), (StatusCode, String)> {
    let rec = sqlx::query_as::<_, ChargeRecord>(
        "INSERT INTO charges (account_number, service_type, charge_date, amount) VALUES ($1,$2,$3,$4) RETURNING *")
        .bind(&p.account_number).bind(&p.service_type).bind(p.charge_date).bind(p.amount)
        .fetch_one(&pool).await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok((StatusCode::CREATED, Json(rec)))
}

async fn update_charge(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
    Json(p): Json<ChargeRequest>,
) -> Result<Json<ChargeRecord>, (StatusCode, String)> {
    sqlx::query_as::<_, ChargeRecord>(
        "UPDATE charges SET account_number=$1, service_type=$2, charge_date=$3, amount=$4 WHERE id=$5 RETURNING *")
        .bind(&p.account_number).bind(&p.service_type).bind(p.charge_date).bind(p.amount).bind(id)
        .fetch_optional(&pool).await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json).ok_or_else(|| (StatusCode::NOT_FOUND, "Запись не найдена".to_string()))
}

async fn delete_charge(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
) -> Result<StatusCode, (StatusCode, String)> {
    let r = sqlx::query("DELETE FROM charges WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    if r.rows_affected() == 0 {
        Err((StatusCode::NOT_FOUND, "Запись не найдена".into()))
    } else {
        Ok(StatusCode::NO_CONTENT)
    }
}

// ==========================================
// ОБРАБОТЧИКИ: PAYMENTS
// ==========================================
async fn get_all_payments(
    State(pool): State<PgPool>,
) -> Result<Json<Vec<PaymentRecord>>, (StatusCode, String)> {
    sqlx::query_as::<_, PaymentRecord>(
        "SELECT * FROM payments ORDER BY NULLIF(regexp_replace(account_number, '\\D', '', 'g'), '')::INT NULLS LAST, account_number, payment_date")
        .fetch_all(&pool).await.map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

async fn get_payment_by_id(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
) -> Result<Json<PaymentRecord>, (StatusCode, String)> {
    sqlx::query_as::<_, PaymentRecord>("SELECT * FROM payments WHERE id = $1")
        .bind(id)
        .fetch_optional(&pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json)
        .ok_or_else(|| (StatusCode::NOT_FOUND, "Запись не найдена".to_string()))
}

async fn create_payment(
    State(pool): State<PgPool>,
    Json(p): Json<PaymentRequest>,
) -> Result<(StatusCode, Json<PaymentRecord>), (StatusCode, String)> {
    let rec = sqlx::query_as::<_, PaymentRecord>(
        "INSERT INTO payments (account_number, payment_date, amount, payment_method) VALUES ($1,$2,$3,$4) RETURNING *")
        .bind(&p.account_number).bind(p.payment_date).bind(p.amount).bind(&p.payment_method)
        .fetch_one(&pool).await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok((StatusCode::CREATED, Json(rec)))
}

async fn update_payment(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
    Json(p): Json<PaymentRequest>,
) -> Result<Json<PaymentRecord>, (StatusCode, String)> {
    sqlx::query_as::<_, PaymentRecord>(
        "UPDATE payments SET account_number=$1, payment_date=$2, amount=$3, payment_method=$4 WHERE id=$5 RETURNING *")
        .bind(&p.account_number).bind(p.payment_date).bind(p.amount).bind(&p.payment_method).bind(id)
        .fetch_optional(&pool).await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map(Json).ok_or_else(|| (StatusCode::NOT_FOUND, "Запись не найдена".to_string()))
}

async fn delete_payment(
    Path(id): Path<i32>,
    State(pool): State<PgPool>,
) -> Result<StatusCode, (StatusCode, String)> {
    let r = sqlx::query("DELETE FROM payments WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    if r.rows_affected() == 0 {
        Err((StatusCode::NOT_FOUND, "Запись не найдена".into()))
    } else {
        Ok(StatusCode::NO_CONTENT)
    }
}

// ==========================================
// ОБРАБОТЧИКИ: ОТЧЕТЫ
// ==========================================
async fn report_turnover(
    State(pool): State<PgPool>,
    Query(q): Query<YearQuery>,
) -> Result<Json<Vec<TurnoverRow>>, (StatusCode, String)> {
    sqlx::query_as::<_, TurnoverRow>("SELECT * FROM fn_report_turnover($1)")
        .bind(q.year)
        .fetch_all(&pool)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

async fn report_turnover_account(
    Path(account): Path<String>,
    State(pool): State<PgPool>,
    Query(q): Query<RangeQuery>,
) -> Result<Json<Vec<TurnoverAccountRow>>, (StatusCode, String)> {
    sqlx::query_as::<_, TurnoverAccountRow>("SELECT * FROM fn_report_turnover_account($1,$2,$3)")
        .bind(&account)
        .bind(q.from)
        .bind(q.to)
        .fetch_all(&pool)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

async fn report_debtors(
    State(pool): State<PgPool>,
    Query(q): Query<AsOfQuery>,
) -> Result<Json<Vec<DebtorRow>>, (StatusCode, String)> {
    sqlx::query_as::<_, DebtorRow>("SELECT * FROM fn_report_debtors($1)")
        .bind(q.as_of)
        .fetch_all(&pool)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
}

// ==========================================
// MAIN
// ==========================================
#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let database_url = env::var("DATABASE_URL").expect("DATABASE_URL должен быть установлен");
    tracing::info!("Подключение к базе данных...");

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(std::time::Duration::from_secs(30))
        .connect(&database_url)
        .await
        .expect("Не удалось подключиться к PostgreSQL.");
    tracing::info!("База данных подключена!");

    let static_router = Router::new()
        .fallback_service(ServeDir::new("static").append_index_html_on_directories(true))
        .layer(middleware::from_fn(cache_control_middleware));

    let app = Router::new()
        .route("/api/saldo", get(get_all_saldos).post(create_saldo))
        .route(
            "/api/saldo/{id}",
            get(get_saldo_by_id).put(update_saldo).delete(delete_saldo),
        )
        .route("/api/charges", get(get_all_charges).post(create_charge))
        .route(
            "/api/charges/{id}",
            get(get_charge_by_id)
                .put(update_charge)
                .delete(delete_charge),
        )
        .route("/api/payments", get(get_all_payments).post(create_payment))
        .route(
            "/api/payments/{id}",
            get(get_payment_by_id)
                .put(update_payment)
                .delete(delete_payment),
        )
        .route("/api/reports/turnover", get(report_turnover))
        .route(
            "/api/reports/turnover/{account}",
            get(report_turnover_account),
        )
        .route("/api/reports/debtors", get(report_debtors))
        .with_state(pool)
        .fallback_service(static_router);

    let port = env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}"))
        .await
        .unwrap();
    tracing::info!("Сервер запущен: http://localhost:{port}");
    axum::serve(listener, app).await.unwrap();
}

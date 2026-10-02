use axum::{extract::State, http::StatusCode, routing::get, Json, Router};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use sqlx::{postgres::PgPoolOptions, FromRow, PgPool};
use std::env;
use tower_http::services::ServeDir;

#[derive(FromRow, serde::Serialize, Clone)]
struct SaldoRecord {
    id: i32,
    account_number: String,
    period_date: NaiveDate,
    amount: Decimal,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let database_url = env::var("DATABASE_URL").expect("DATABASE_URL должен быть установлен");
    let safe_url = database_url.replace("saldo:saldo", "***:***");
    tracing::info!("Подключение к базе данных: {}", safe_url);

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("Не удалось подключиться к PostgreSQL.");

    tracing::info!("База данных подключена!");

    let api_routes = Router::new()
        .route("/saldo", get(get_saldo_json))
        .with_state(pool);

    let app = Router::new()
        .nest("/api", api_routes)
        .fallback_service(ServeDir::new("static").append_index_html_on_directories(true));

    let port = env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let addr = format!("0.0.0.0:{}", port);

    tracing::info!("🚀 Сервер запущен: http://localhost:{}", port);
    tracing::info!("   API:   http://localhost:{}/api/saldo", port);
    tracing::info!("   UI:    http://localhost:{}/", port);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn get_saldo_json(
    State(pool): State<PgPool>,
) -> Result<Json<Vec<SaldoRecord>>, (StatusCode, String)> {
    let records = sqlx::query_as::<_, SaldoRecord>(
        "SELECT id, account_number, period_date, amount
         FROM saldo
         ORDER BY account_number, period_date DESC
         LIMIT 20"
    )
    .fetch_all(&pool)
    .await
    .map_err(|e| {
        tracing::error!("Ошибка БД: {}", e);
        (StatusCode::INTERNAL_SERVER_ERROR, "Ошибка базы данных".to_string())
    })?;

    Ok(Json(records))
}

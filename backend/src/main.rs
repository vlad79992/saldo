use axum::{
    extract::State,
    http::{header, HeaderValue, StatusCode},
    routing::get,
    Json, Router,
};
use chrono::NaiveDate;
use rust_decimal::Decimal;
use sqlx::{postgres::PgPoolOptions, FromRow, PgPool};
use std::env;
use tower_http::{
    services::ServeDir,
    set_header::{MakeHeaderValue, SetResponseHeader},
};

#[derive(FromRow, serde::Serialize, Clone)]
struct SaldoRecord {
    id: i32,
    account_number: String,
    period_date: NaiveDate,
    amount: Decimal,
}

/// Хелпер для ServeDir: статика с хэшами в именах (WASM/JS от Trunk) кэшируем надолго,
/// index.html и корень — отдаём без кэша, чтобы браузер всегда получал свежий бандл.
fn is_hashed_asset(path: &str) -> bool {
    path != "/" && !path.ends_with(".html")
}

/// Значение Cache-Control по пути запроса.
const IMMUTABLE: &str = "public, max-age=31536000, immutable";
const NO_CACHE: &str = "no-cache";

/// Макер заголовка для SetResponseHeader. В tower-http 0.6 трейт
/// `MakeHeaderValue<T>` реализован для `T = Response<ResBody>`; исходный путь
/// запроса в объекте ответа недоступен, поэтому он передаётся через extension,
/// который проставляет middleware-замыкание ниже (в main). Если extension отсутствует
/// — возвращаем None и оставляем ответ как есть.
#[derive(Clone)]
struct CacheControlByPath;

/// Extension с путём исходного запроса (проставляется middleware в main).
#[derive(Clone)]
struct RequestPath(String);

impl<B> MakeHeaderValue<axum::response::Response<B>> for CacheControlByPath {
    fn make_header_value(
        &mut self,
        message: &axum::response::Response<B>,
    ) -> Option<HeaderValue> {
        let path = message
            .extensions()
            .get::<RequestPath>()
            .map(|p| p.0.as_str())?;
        Some(HeaderValue::from_static(if is_hashed_asset(path) {
            IMMUTABLE
        } else {
            NO_CACHE
        }))
    }
}

/// Слой-обёртка над сервисом статики: запоминает путь запроса, приводит тело ответа
/// к axum::body::Body (fallback_service Router требует именно Request<Body>) и кладёт
/// путь в extensions ответа. Работает с любым S::Response: http_body::Body — это
/// supertrait для axum::body::Body, поэтому конвертация идёт через Body::new.
#[derive(Clone)]
struct AddRequestPath<S>(S);

impl<S> tower::Service<axum::http::Request<axum::body::Body>> for AddRequestPath<S>
where
    S: tower::Service<axum::http::Request<axum::body::Body>>,
    S::Response: http_body::Body + Send + 'static,
    S::Response::Data: Send,
    S::Error: Into<axum::BoxError>,
    S::Future: Send + 'static,
{
    type Response = axum::response::Response;
    type Error = axum::BoxError;
    type Future =
        std::pin::Pin<Box<dyn std::future::Future<Output = Result<Self::Response, Self::Error>> + Send>>;

    fn poll_ready(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        self.0.poll_ready(cx).map_err(Into::into)
    }

    fn call(&mut self, req: axum::http::Request<axum::body::Body>) -> Self::Future {
        let path = req.uri().path().to_owned();
        let fut = self.0.call(req);
        Box::pin(async move {
            let resp = fut.await.map_err(Into::into)?;
            let mut resp = axum::response::Response::new(axum::body::Body::new(resp));
            resp.extensions_mut().insert(RequestPath(path));
            Ok(resp)
        })
    }
}

type BoxError = Box<dyn std::error::Error + Send + Sync>;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let database_url = env::var("DATABASE_URL").expect("DATABASE_URL должен быть установлен");
    let safe_url = database_url.replace("saldo:saldo", "***:***");
    tracing::info!("Подключение к базе данных: {}", safe_url);

    let pool = PgPoolOptions::new()
        .max_connections(5)
        // acquire_timeout: 30 сек — больше шансов дождаться поднятия БД при холодном старте compose
        .acquire_timeout(std::time::Duration::from_secs(30))
        .connect(&database_url)
        .await
        .expect("Не удалось подключиться к PostgreSQL.");

    tracing::info!("База данных подключена!");

    // Axum 0.8: path parameters обязательны, поэтому регистрируем полный путь напрямую
    // (вместо nest("/api") + route("/saldo"), как это было в axum 0.7)
    let app = Router::new()
        .route("/api/saldo", get(get_saldo_json))
        .with_state(pool)
        // Статика: хэшированные ассеты кэшируем на год, index.html — без кэша.
        // В tower-http 0.6 у ServeDir нет метода insert_response_header_if, поэтому
        // оборачиваем его в SetResponseHeader (overriding) с макером CacheControlByPath.
        // Путь запроса передаётся макеру через extension: его проставляет middleware
        // AddRequestPath (кладёт путь в extensions ответа; SetResponseHeader сохраняет
        // extensions и лишь перезаписывает заголовок).
        .fallback_service(AddRequestPath(SetResponseHeader::overriding(
            ServeDir::new("static").append_index_html_on_directories(true),
            header::CACHE_CONTROL,
            CacheControlByPath,
        )));

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

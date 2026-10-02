use chrono::NaiveDate;
use dioxus::prelude::*;
use gloo_net::http::Request;
use rust_decimal::Decimal;
use serde::Deserialize;

#[derive(Clone, Deserialize, Debug)]
struct SaldoRecord {
    id: i32,
    account_number: String,
    period_date: NaiveDate,
    amount: Decimal,
}

fn main() {
    // Инициализируем panic hook для лучшей отладки WASM
    console_error_panic_hook::set_once();
    launch(App);
}

#[component]
fn App() -> Element {
    let saldo_data = use_resource(|| async move {
        match Request::get("/api/saldo").send().await {
            Ok(response) => match response.json::<Vec<SaldoRecord>>().await {
                Ok(data) => data,
                Err(_e) => {
                    web_sys::console::error_1(&"Ошибка парсинга JSON".into());
                    vec![]
                }
            },
            Err(_e) => {
                web_sys::console::error_1(&"Ошибка запроса".into());
                vec![]
            }
        }
    });

    rsx! {
        div {
            class: "min-h-screen bg-gray-100 p-8 font-sans",
            div {
                class: "max-w-4xl mx-auto bg-white shadow-xl rounded-lg overflow-hidden",

                div {
                    class: "bg-blue-600 text-white p-6",
                    h1 { class: "text-3xl font-bold", "🦀 Сальдо на чистом Rust" }
                    p { class: "text-blue-100 mt-2", "Бэкенд: Axum | Фронтенд: Dioxus (WASM)" }
                }

                div {
                    class: "p-6",

                    match saldo_data.read().as_ref() {
                        Some(records) if records.is_empty() => {
                            rsx! {
                                p {
                                    class: "text-center text-gray-500",
                                    "Записей не найдено"
                                }
                            }
                        }
                        Some(records) => {
                            rsx! {
                                div {
                                    class: "overflow-x-auto",
                                    table {
                                        class: "w-full text-left border-collapse",

                                        thead {
                                            tr {
                                                class: "bg-gray-50 text-gray-600 uppercase text-sm",
                                                th { class: "py-3 px-6", "ID" }
                                                th { class: "py-3 px-6", "Лицевой счет" }
                                                th { class: "py-3 px-6", "Период" }
                                                th { class: "py-3 px-6 text-right", "Сумма (₽)" }
                                            }
                                        }

                                        tbody {
                                            class: "text-gray-600 text-sm",

                                            // ВАЖНО: итерируемся по клонированным значениям
                                            for record in records.clone() {
                                                tr {
                                                    key: "{record.id}",
                                                    class: "border-b border-gray-200 hover:bg-blue-50 transition",

                                                    td { class: "py-3 px-6", "{record.id}" }

                                                    td {
                                                        class: "py-3 px-6 font-medium text-gray-900",
                                                        "Кв. {record.account_number}"
                                                    }

                                                    td {
                                                        class: "py-3 px-6",
                                                        "{record.period_date.format("%d.%m.%Y")}"
                                                    }

                                                    td {
                                                        class: "py-3 px-6 text-right font-bold",

                                                        span {
                                                            class: if record.amount < Decimal::ZERO {
                                                                "text-red-500"
                                                            } else {
                                                                "text-green-600"
                                                            },
                                                            "{record.amount}"
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        None => {
                            rsx! {
                                p {
                                    class: "text-center text-gray-500",
                                    "Загрузка данных..."
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

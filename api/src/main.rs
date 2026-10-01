use arrivau_api::{app, AppState};
use std::{env, error::Error, net::SocketAddr};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
    let demo_enabled = env::var("ARRIVAU_DEMO").as_deref() == Ok("1");
    let path = env::var("ARRIVAU_DB_PATH").unwrap_or_else(|_| "arrivau.sqlite3".into());
    let address: SocketAddr = env::var("ARRIVAU_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:8080".into())
        .parse()?;
    if !address.ip().is_loopback() {
        return Err("Demo authentication may only bind to a loopback address".into());
    }
    let state = AppState::open(path, demo_enabled).map_err(std::io::Error::other)?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    tracing::warn!(address = %listener.local_addr()?, "LOCAL DEMO ONLY: fixed bearer tokens, approximate routes, no production authentication");
    axum::serve(listener, app(state))
        .with_graceful_shutdown(async {
            if let Err(error) = tokio::signal::ctrl_c().await {
                tracing::error!(%error, "shutdown signal unavailable");
            }
        })
        .await?;
    Ok(())
}

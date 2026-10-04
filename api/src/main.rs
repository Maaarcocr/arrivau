use arrivau_api::{app, auth::ProductionConfig, AppState};
use std::{env, error::Error, net::SocketAddr, path::PathBuf};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
    let legacy_demo = env::var("ARRIVAU_DEMO").as_deref() == Ok("1");
    let mode = env::var("ARRIVAU_MODE").unwrap_or_else(|_| {
        if legacy_demo {
            "demo".into()
        } else {
            String::new()
        }
    });
    let address: SocketAddr = env::var("ARRIVAU_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:8080".into())
        .parse()?;
    // HTTP is allowed only on loopback or explicitly acknowledged private proxy ingress.
    // ARRIVAU_TLS_PROXY is an operator assertion, not TLS validation in this process.
    if !address.ip().is_loopback()
        && !(mode == "production"
            && env::var("ARRIVAU_TLS_PROXY").as_deref() == Ok("1")
            && env::var("ARRIVAU_ALLOW_NON_LOOPBACK").as_deref() == Ok("1"))
    {
        return Err("Non-loopback requires production mode, ARRIVAU_TLS_PROXY=1 and ARRIVAU_ALLOW_NON_LOOPBACK=1 for private HTTPS-proxy ingress".into());
    }
    let state = match mode.as_str() {
        "demo" => {
            if env::var_os("ARRIVAU_AUTH_CONFIG").is_some() { return Err("Demo mode cannot load production account configuration".into()); }
            let path = env::var("ARRIVAU_DB_PATH").unwrap_or_else(|_| "arrivau-demo.sqlite3".into());
            tracing::warn!(%address,"ISOLATED DEMO: public fixture tokens; never proxy, expose, or use customer data");
            AppState::open(path,true)
        }
        "production" => {
            if legacy_demo { return Err("ARRIVAU_DEMO=1 conflicts with production mode".into()); }
            if env::var("ARRIVAU_TLS_PROXY").as_deref() != Ok("1") { return Err("Production requires ARRIVAU_TLS_PROXY=1 and configured trusted HTTPS reverse-proxy ingress".into()); }
            let path = PathBuf::from(env::var("ARRIVAU_DB_PATH").map_err(|_| "Production requires ARRIVAU_DB_PATH")?);
            let config_path = PathBuf::from(env::var("ARRIVAU_AUTH_CONFIG").map_err(|_| "Production requires ARRIVAU_AUTH_CONFIG")?);
            if !config_path.is_absolute() { return Err("ARRIVAU_AUTH_CONFIG must be an absolute operator-managed file path".into()); }
            let contents = std::fs::read_to_string(config_path)?;
            let config: ProductionConfig = serde_json::from_str(&contents)?;
            tracing::info!(%address,"Configured team-isolated pilot; HTTPS termination and access control required at proxy");
            AppState::open_production(path,config)
        }
        _ => return Err("Set ARRIVAU_MODE=production with account/HTTPS configuration, or explicitly choose ARRIVAU_MODE=demo for loopback fixtures".into()),
    }.map_err(std::io::Error::other)?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    let dispatcher = state.spawn_dispatcher(std::time::Duration::from_secs(5));
    axum::serve(listener, app(state))
        .with_graceful_shutdown(async {
            if let Err(error) = tokio::signal::ctrl_c().await {
                tracing::error!(%error,"shutdown signal unavailable");
            }
        })
        .await?;
    dispatcher.abort();
    Ok(())
}

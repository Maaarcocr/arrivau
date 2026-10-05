use arrivau_api::{app, privacy::PrivacyNotice, AppState};
use reqwest::{Client, StatusCode};

#[tokio::test]
async fn privacy_is_public_but_account_data_stays_authenticated() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("privacy.html");
    let html = "<!doctype html><html lang=\"it\"><body>Informativa di test</body></html>";
    std::fs::write(&path, html).unwrap();
    for configured in [false, true] {
        let mut state = AppState::open(":memory:", true).unwrap();
        if configured {
            state = state.with_privacy_notice(PrivacyNotice::from_path(&path).unwrap());
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app(state)).await.unwrap() });
        let client = Client::new();
        let response = client.get(format!("{base}/privacy")).send().await.unwrap();
        assert_eq!(
            response.status(),
            if configured {
                StatusCode::OK
            } else {
                StatusCode::SERVICE_UNAVAILABLE
            }
        );
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert!(response.headers().get("set-cookie").is_none());
        if configured {
            assert_eq!(response.text().await.unwrap(), html);
        } else {
            assert!(response
                .text()
                .await
                .unwrap()
                .contains("Informativa privacy non disponibile"));
        }
        assert_eq!(
            client
                .get(format!("{base}/v1/me"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            client
                .head(format!("{base}/privacy"))
                .send()
                .await
                .unwrap()
                .status(),
            if configured {
                StatusCode::OK
            } else {
                StatusCode::SERVICE_UNAVAILABLE
            }
        );
        task.abort();
    }
}

//! Public privacy notice. Drafts stay outside the served application until approved.
use axum::{
    extract::State,
    http::StatusCode,
    response::{Html, IntoResponse, Response},
};
use std::{path::Path, sync::Arc};

use crate::AppState;

#[derive(Clone, Default)]
pub struct PrivacyNotice(Option<Arc<str>>);

impl PrivacyNotice {
    /// The operator supplies the final, approved notice; this is not legal validation.
    /// Missing configuration is safe for existing deployments but is not review-ready.
    pub fn from_env() -> Result<Self, String> {
        match std::env::var_os("ARRIVAU_PRIVACY_NOTICE_PATH") {
            None => Ok(Self::default()),
            Some(path) => Self::from_path(Path::new(&path)),
        }
    }

    pub fn from_path(path: &Path) -> Result<Self, String> {
        if !path.is_absolute() {
            return Err("ARRIVAU_PRIVACY_NOTICE_PATH must be an absolute path".into());
        }
        let html = std::fs::read_to_string(path)
            .map_err(|_| "Cannot read ARRIVAU_PRIVACY_NOTICE_PATH as UTF-8".to_owned())?;
        Self::from_html(html)
    }

    fn from_html(html: String) -> Result<Self, String> {
        if !html.contains("<html")
            || !html.contains("</html>")
            || html.contains("[[")
            || html.contains("ARRIVAU_PRIVACY_DRAFT")
        {
            return Err(
                "Privacy notice must be complete HTML without draft markers or [[placeholders]]"
                    .into(),
            );
        }
        Ok(Self(Some(html.into())))
    }

    fn response(&self) -> Response {
        let (status, html) = match &self.0 {
            Some(html) => (StatusCode::OK, html.to_string()),
            None => (
                StatusCode::SERVICE_UNAVAILABLE,
                "<!doctype html><html lang=\"it\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Privacy Arrivau non disponibile</title><main><h1>Informativa privacy non disponibile</h1><p>Il gestore non ha ancora pubblicato l’informativa per questo server. Riprova più tardi.</p></main></html>".into(),
            ),
        };
        (
            status,
            [
                ("content-language", "it"),
                ("referrer-policy", "no-referrer"),
                ("x-robots-tag", "noindex"),
                ("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
            ],
            Html(html),
        )
            .into_response()
    }
}

pub(crate) async fn show(State(state): State<AppState>) -> Response {
    state.privacy_notice.response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_incomplete_notice_cannot_be_served_as_a_policy() {
        assert_eq!(
            PrivacyNotice::default().response().status(),
            StatusCode::SERVICE_UNAVAILABLE
        );
        for html in [
            "Not an HTML document",
            "<html>[[CONTACT]]</html>",
            "<html>ARRIVAU_PRIVACY_DRAFT</html>",
        ] {
            assert!(PrivacyNotice::from_html(html.into()).is_err());
        }
        assert!(PrivacyNotice::from_path(Path::new("relative.html")).is_err());
    }

    #[test]
    fn approved_notice_is_html_with_no_third_party_subresources() {
        let notice = PrivacyNotice::from_html(
            "<html lang=\"it\"><body>Informativa approvata</body></html>".into(),
        )
        .unwrap();
        let response = notice.response();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()["content-type"],
            "text/html; charset=utf-8"
        );
        assert_eq!(response.headers()["referrer-policy"], "no-referrer");
        assert!(response.headers()["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("default-src 'none'"));
    }
}

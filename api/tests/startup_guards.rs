//! Exercise executable fail-closed settings without opening a listening socket.
use std::process::Command;
use tempfile::TempDir;

fn rejected(env: &[(&str, &str)], expected: &str) {
    let dir = TempDir::new().unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_arrivau-api"));
    for key in [
        "ARRIVAU_MODE",
        "ARRIVAU_DEMO",
        "ARRIVAU_DB_PATH",
        "ARRIVAU_APP_CONFIG",
        "ARRIVAU_TLS_PROXY",
        "ARRIVAU_ALLOW_NON_LOOPBACK",
        "ARRIVAU_ADDR",
        "ARRIVAU_ROUTING",
        "ARRIVAU_OSRM_DATASET",
        "ARRIVAU_PRIVACY_NOTICE_PATH",
    ] {
        command.env_remove(key);
    }
    command.current_dir(dir.path()).envs(env.iter().copied());
    let output = command.output().unwrap();
    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains(expected),
        "unexpected stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        std::fs::read_dir(dir.path()).unwrap().next().is_none(),
        "invalid settings must not create a database"
    );
}

#[test]
fn binary_requires_explicit_mode_and_secure_ingress_configuration() {
    rejected(&[], "Set ARRIVAU_MODE=production");
    rejected(
        &[("ARRIVAU_MODE", "demo"), ("ARRIVAU_ADDR", "0.0.0.0:8080")],
        "Non-loopback requires production",
    );
    rejected(
        &[
            ("ARRIVAU_MODE", "demo"),
            ("ARRIVAU_ADDR", "0.0.0.0:8080"),
            ("ARRIVAU_ALLOW_NON_LOOPBACK", "1"),
            ("ARRIVAU_TLS_PROXY", "1"),
        ],
        "Non-loopback requires production",
    );
    rejected(
        &[("ARRIVAU_MODE", "demo"), ("ARRIVAU_APP_CONFIG", "/missing")],
        "Demo mode cannot load production",
    );
    rejected(
        &[("ARRIVAU_MODE", "production"), ("ARRIVAU_DEMO", "1")],
        "conflicts with production",
    );
    rejected(
        &[("ARRIVAU_MODE", "production")],
        "requires ARRIVAU_TLS_PROXY=1",
    );
    rejected(
        &[
            ("ARRIVAU_MODE", "production"),
            ("ARRIVAU_TLS_PROXY", "1"),
            ("ARRIVAU_ADDR", "0.0.0.0:8080"),
        ],
        "Non-loopback requires production",
    );
    rejected(
        &[("ARRIVAU_MODE", "production"), ("ARRIVAU_TLS_PROXY", "1")],
        "requires ARRIVAU_DB_PATH",
    );
    rejected(
        &[
            ("ARRIVAU_MODE", "production"),
            ("ARRIVAU_TLS_PROXY", "1"),
            ("ARRIVAU_DB_PATH", "/tmp/unused.db"),
        ],
        "requires ARRIVAU_APP_CONFIG",
    );
    rejected(
        &[
            ("ARRIVAU_MODE", "production"),
            ("ARRIVAU_TLS_PROXY", "1"),
            ("ARRIVAU_DB_PATH", "/tmp/unused.db"),
            ("ARRIVAU_APP_CONFIG", "relative.json"),
        ],
        "absolute operator-managed",
    );
}

#[test]
fn privacy_notice_configuration_fails_before_database_creation_when_invalid() {
    rejected(
        &[
            ("ARRIVAU_MODE", "demo"),
            ("ARRIVAU_PRIVACY_NOTICE_PATH", "relative.html"),
        ],
        "ARRIVAU_PRIVACY_NOTICE_PATH must be an absolute path",
    );
    rejected(
        &[
            ("ARRIVAU_MODE", "demo"),
            (
                "ARRIVAU_PRIVACY_NOTICE_PATH",
                "/nonexistent/arrivau-privacy.html",
            ),
        ],
        "Cannot read ARRIVAU_PRIVACY_NOTICE_PATH",
    );
}

#[test]
fn routing_opt_in_fails_before_database_creation_when_misconfigured() {
    rejected(
        &[("ARRIVAU_MODE", "demo"), ("ARRIVAU_ROUTING", "remote")],
        "ARRIVAU_ROUTING must be",
    );
    rejected(
        &[
            ("ARRIVAU_MODE", "demo"),
            ("ARRIVAU_OSRM_DATASET", "/unused/manifest.json"),
        ],
        "ARRIVAU_OSRM_DATASET requires",
    );
    #[cfg(not(feature = "embedded-osrm"))]
    rejected(
        &[
            ("ARRIVAU_MODE", "demo"),
            ("ARRIVAU_ROUTING", "embedded-osrm"),
        ],
        "Rebuild with --features embedded-osrm",
    );
    #[cfg(feature = "embedded-osrm")]
    rejected(
        &[
            ("ARRIVAU_MODE", "demo"),
            ("ARRIVAU_ROUTING", "embedded-osrm"),
            ("ARRIVAU_OSRM_DATASET", "relative.json"),
        ],
        "manifest path must be absolute",
    );
}

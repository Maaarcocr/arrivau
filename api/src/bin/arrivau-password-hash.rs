//! Offline helper. Never accepts a password in argv or writes a credentials file.
use std::io::{self, IsTerminal, Read};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let password = if io::stdin().is_terminal() {
        let first = rpassword::prompt_password("New individual password (12+ bytes): ")?;
        let second = rpassword::prompt_password("Confirm password: ")?;
        if first != second {
            return Err("Passwords do not match".into());
        }
        first
    } else {
        let mut value = String::new();
        io::stdin().take(1026).read_to_string(&mut value)?;
        value.trim_end_matches(['\r', '\n']).to_owned()
    };
    println!(
        "{}",
        arrivau_api::auth::hash_password(&password).map_err(io::Error::other)?
    );
    Ok(())
}

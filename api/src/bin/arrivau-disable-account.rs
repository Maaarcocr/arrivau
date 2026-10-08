//! Run by the operator against a backed-up existing database, preferably while API is stopped.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        return Err(
            "Usage: arrivau-disable-invited-account /absolute/pilot.sqlite3 lowercase-username"
                .into(),
        );
    }
    arrivau_api::auth::disable_account(std::path::Path::new(&args[0]), &args[1])
        .map_err(std::io::Error::other)?;
    println!("Account disabled; sessions revoked and delivery history preserved.");
    Ok(())
}

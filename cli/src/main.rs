mod clipboard;
mod config;
mod cwd;
mod osc52;
mod paste;
mod proxy;
mod session;
mod sshcfg;
mod term;
mod upload;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "devbox",
    version,
    about = "SSH terminal with a native clipboard & file bridge"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Connect to a host: `devbox connect prod`, `devbox connect user@host -p 2222`
    Connect {
        /// host alias (devbox config / ~/.ssh/config) or [user@]host
        target: String,
        /// port (overrides config)
        #[arg(short, long)]
        port: Option<u16>,
        /// identity file (overrides config)
        #[arg(short, long)]
        identity: Option<String>,
        /// remote inbox directory for uploads (default: ~/.devbox/inbox on the remote)
        #[arg(long)]
        inbox: Option<String>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Connect {
            target,
            port,
            identity,
            inbox,
        } => {
            let resolved = config::resolve(&target, port, identity, inbox)?;
            proxy::run(resolved).await
        }
    }
}

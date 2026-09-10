mod clipboard;
mod config;
mod cwd;
mod modeflap;
mod osc52;
mod paste;
mod proxy;
mod session;
mod sshcfg;
mod term;
mod upload;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "devbox",
    version,
    about = "SSH terminal with a native clipboard & file bridge and terminal protection"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Host alias or user@host to connect to directly: `devbox dev@host`
    #[arg(value_name = "TARGET")]
    target: Option<String>,
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

    /// Run system SSH with automatic terminal restoration on disconnect/crash
    Ssh {
        /// Arguments passed directly to ssh (e.g. user@host, -p 22, -i key)
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },

    /// Reset local terminal modes (disables stuck mouse tracking, bracketed paste, etc.)
    Reset,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::Connect {
            target,
            port,
            identity,
            inbox,
        }) => {
            let resolved = config::resolve(&target, port, identity, inbox)?;
            proxy::run(resolved).await
        }
        Some(Command::Ssh { args }) => run_ssh(&args),
        Some(Command::Reset) => {
            term::restore();
            println!(
                "[devbox] Terminal modes restored (mouse tracking & bracketed paste disabled)."
            );
            Ok(())
        }
        None => {
            if let Some(target) = cli.target {
                let resolved = config::resolve(&target, None, None, None)?;
                proxy::run(resolved).await
            } else {
                use clap::CommandFactory;
                Cli::command().print_help()?;
                println!();
                Ok(())
            }
        }
    }
}

fn run_ssh(args: &[String]) -> Result<()> {
    term::install_signal_handlers();

    let status = std::process::Command::new("ssh")
        .args(args)
        .status()
        .context("failed to execute system ssh command")?;

    term::restore();

    if let Some(code) = status.code() {
        if code != 0 {
            std::process::exit(code);
        }
    }
    Ok(())
}

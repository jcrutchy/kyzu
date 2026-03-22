pub mod app;
pub mod core;
pub mod input;
pub mod render;

fn main()
{
  // We call the app's run function directly.
  // Any critical startup errors are caught here.
  if let Err(e) = crate::app::run()
  {
    eprintln!("[FATAL] Application failed to start: {}", e);
    std::process::exit(1);
  }
}

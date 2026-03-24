use kyzu::app::App;
use kyzu::bake::BakeManager;
use kyzu::core::config;
use kyzu::core::log::Logger;
use winit::event_loop::{ControlFlow, EventLoop};

fn main()
{
  // 1. Load Configuration
  let config = match config::load()
  {
    Ok(c) => c,
    Err(e) =>
    {
      eprintln!("[FATAL] Configuration Error: {}", e);
      std::process::exit(1);
    }
  };

  // 2. Setup Logging
  let mut logger = Logger::new(&config.app.log_filename);

  // 3. Initialize BakeManager with Config and Run Bake
  let bake_manager = BakeManager::new(&config);
  bake_manager.start_bake(&mut logger);

  // 4. Create App
  let mut app = App::new(config, logger);

  // 5. Start Event Loop
  let event_loop = EventLoop::new().expect("Failed to create event loop");
  event_loop.set_control_flow(ControlFlow::Poll);

  if let Err(e) = event_loop.run_app(&mut app)
  {
    eprintln!("Application error: {}", e);
  }
}

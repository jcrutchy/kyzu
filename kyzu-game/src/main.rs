use kyzu::app::App;
use kyzu::bake::BakeManager;
use kyzu::core::config;
use kyzu::core::log::Logger;
use winit::event_loop::{ControlFlow, EventLoop};

fn main()
{
  let config = match config::load()
  {
    Ok(c) => c,
    Err(e) =>
    {
      eprintln!("[FATAL] Configuration Error: {}", e);
      std::process::exit(1);
    }
  };

  let logger = Logger::new(&config.app.log_filename);

  let mut app = App::new(config, logger);

  let mut bake_manager = BakeManager::new();
  bake_manager.start_bake();

  // EXIT HERE for now if you only want to test the baking logic
  std::process::exit(0);

  let event_loop = EventLoop::new().expect("Failed to create event loop");
  event_loop.set_control_flow(ControlFlow::Poll);

  if let Err(e) = event_loop.run_app(&mut app)
  {
    eprintln!("Application error: {}", e);
  }
}

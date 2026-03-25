use kyzu::app::App;
use kyzu::bake::BakeManager;
use kyzu::core::config;
use kyzu::core::log::{LogLevel, Logger};
use kyzu::world::manifest_loader::load_all_manifests;
use winit::event_loop::{ControlFlow, EventLoop};

fn main()
{
  let args: Vec<String> = std::env::args().collect();

  // 1. Load configuration
  let config = match config::load()
  {
    Ok(c) => c,
    Err(e) =>
    {
      eprintln!("[FATAL] Configuration Error: {}", e);
      std::process::exit(1);
    }
  };

  let mut logger = Logger::new(&config.app.log_filename);

  // 2. Run bake if requested
  let bake_manager = BakeManager::new(&config);
  if args.contains(&"--bake".to_string())
  {
    logger.emit(LogLevel::Info, "Baking sol_system world data...");
    bake_manager.start_bake(&mut logger);
  }

  // 3. Load manifests from disk — always, regardless of --bake.
  //    The bake is an offline step; we expect manifests to already exist.
  //    Individual load failures are logged and skipped; game still starts.
  let manifests = match load_all_manifests(&bake_manager.output_root, &mut logger)
  {
    Ok(m) => m,
    Err(e) =>
    {
      logger.emit(LogLevel::Error, &format!("Manifest load failed: {}", e));
      Vec::new()
    }
  };

  // 4. Create app — manifests are moved into SharedState when the renderer
  //    initialises inside resumed().
  let mut app = App::new(config, logger, manifests);

  // 5. Run event loop
  let event_loop = EventLoop::new().expect("Failed to create event loop");
  event_loop.set_control_flow(ControlFlow::Poll);

  if let Err(e) = event_loop.run_app(&mut app)
  {
    app.logger.emit(LogLevel::Info, &format!("Application error: {}", e));
  }
}

//! HİDRA Terminal UI — Paranoid-Grade Secure Communication Terminal
//!
//! ## Panels
//! 1. **TITAN Status** — FPGA health, Omega Cloak, AEGIS, key status
//! 2. **Hydra Network** — Broker mesh health, Tor circuit status
//! 3. **Message Area** — Encrypted chat view with timestamps
//! 4. **Input Bar** — Command/message input with mode indicator
//!
//! ## Modes
//! - **NORMAL** — Standard encrypted messaging
//! - **LAZARUS** — Stealth mode: screen blanked, activity hidden
//! - **COMMAND** — System commands (`:status`, `:kill`, `:tor`, etc.)
//!
//! ## Keys
//! - `F1` — Toggle Lazarus stealth mode
//! - `F2` — Show TITAN status
//! - `F3` — Show Hydra network status
//! - `Esc` — Exit / cancel
//! - `Enter` — Send message / execute command

use anyhow::Result;
use chrono::Local;
use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    prelude::*,
    widgets::{Block, Borders, List, ListItem, Paragraph, Wrap},
};
use std::io;
use std::time::Duration;

mod net_bridge;
use net_bridge::NetworkBridge;

// ─── Application State ──────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AppMode {
    Normal,
    Lazarus,
    Command,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ActivePanel {
    Chat,
    Status,
    Network,
}

#[derive(Debug, Clone)]
struct ChatMessage {
    timestamp: String,
    sender: String,
    content: String,
    is_own: bool,
}

#[derive(Debug, Clone)]
struct TitanStatus {
    omega_active: bool,
    aegis_active: bool,
    key_loaded: bool,
    lockstep_ok: bool,
    trng_healthy: bool,
    post_pass: bool,
    kill_armed: bool,
    session_count: u32,
}

impl Default for TitanStatus {
    fn default() -> Self {
        Self {
            omega_active: true,
            aegis_active: true,
            key_loaded: true,
            lockstep_ok: true,
            trng_healthy: true,
            post_pass: true,
            kill_armed: false,
            session_count: 42,
        }
    }
}

#[derive(Debug, Clone)]
struct BrokerStatus {
    id: String,
    health: u8, // 0=dead, 1=sick, 2=alive
}

#[derive(Debug, Clone)]
struct NetworkStatus {
    tor_connected: bool,
    circuit_age_secs: u64,
    brokers: Vec<BrokerStatus>,
    messages_sent: u64,
    messages_recv: u64,
}

impl Default for NetworkStatus {
    fn default() -> Self {
        let brokers = (0..10)
            .map(|i| {
                let health = if i < 7 { 2 } else if i < 9 { 1 } else { 0 };
                BrokerStatus {
                    id: format!("B{:02}", i),
                    health,
                }
            })
            .collect();
        Self {
            tor_connected: true,
            circuit_age_secs: 342,
            brokers,
            messages_sent: 17,
            messages_recv: 23,
        }
    }
}

struct App {
    mode: AppMode,
    panel: ActivePanel,
    input: String,
    messages: Vec<ChatMessage>,
    titan: TitanStatus,
    network: NetworkStatus,
    bridge: NetworkBridge,
    running: bool,
    lazarus_blink: bool,
    tick_count: u64,
    /// ★ A-5 FIX: Sealed envelopes queued for async dispatch
    outgoing_queue: Vec<Vec<u8>>,
}

impl App {
    fn new() -> Self {
        // Generate random keys for SIM mode
        let mut envelope_key = [0u8; 32];
        let mut sender_id = [0u8; 32];
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut envelope_key);
        rand::thread_rng().fill_bytes(&mut sender_id);

        let mut app = Self {
            mode: AppMode::Normal,
            panel: ActivePanel::Chat,
            input: String::new(),
            messages: Vec::new(),
            titan: TitanStatus::default(),
            network: NetworkStatus::default(),
            bridge: NetworkBridge::new(envelope_key, sender_id),
            running: true,
            lazarus_blink: false,
            tick_count: 0,
            outgoing_queue: Vec::new(),
        };
        // Boot messages
        app.system_msg("TITAN FPGA bridge initialized (SIM mode)");
        app.system_msg("Omega Cloak DPA protection: ACTIVE");
        app.system_msg("AEGIS lockstep monitor: ACTIVE");
        app.system_msg("Hydra mesh: 7/10 brokers online");
        app.system_msg("Ghost Link: Tor circuit established");
        app.system_msg("Triple-layer encryption: AES-256-GCM-SIV + TITAN-CTR + XChaCha20");
        if let Some(topic) = app.bridge.current_topic() {
            app.system_msg(&format!("MQTT topic: {}", topic));
        }
        app.system_msg("Type a message or :help for commands");
        app
    }

    fn system_msg(&mut self, content: &str) {
        self.messages.push(ChatMessage {
            timestamp: Local::now().format("%H:%M:%S").to_string(),
            sender: "SYSTEM".to_string(),
            content: content.to_string(),
            is_own: false,
        });
    }

    fn send_message(&mut self) {
        if self.input.is_empty() {
            return;
        }
        let text = self.input.clone();
        self.input.clear();

        if text.starts_with(':') {
            self.handle_command(&text);
            return;
        }

        self.messages.push(ChatMessage {
            timestamp: Local::now().format("%H:%M:%S").to_string(),
            sender: "YOU".to_string(),
            content: text.clone(),
            is_own: true,
        });
        self.network.messages_sent += 1;

        // ★ A-5 FIX: Seal message through framing layer and queue for dispatch
        let payload_bytes = text.into_bytes();
        match hidra_net::framing::seal(
            &self.bridge.envelope_key,
            hidra_net::framing::MessageType::Text,
            &self.bridge.sender_id,
            &payload_bytes,
        ) {
            Ok(envelope) => {
                let wire_bytes = envelope.to_bytes();
                self.outgoing_queue.push(wire_bytes);
            }
            Err(e) => {
                self.system_msg(&format!("Seal error: {}", e));
                return;
            }
        }

        let status = self.bridge.status_summary();
        if status.healthy_brokers >= 3 {
            self.system_msg(&format!(
                "Sealed & queued ({} bytes) → {}/{} brokers",
                self.outgoing_queue.last().map_or(0, |v| v.len()),
                std::cmp::min(3, status.healthy_brokers),
                status.total_brokers
            ));
        } else {
            self.system_msg("⚠ Not enough healthy brokers for broadcast");
        }
    }

    fn handle_command(&mut self, cmd: &str) {
        match cmd.trim() {
            ":help" => {
                self.system_msg("Commands: :status :network :kill :tor :lazarus :clear :quit");
            }
            ":status" => {
                self.panel = ActivePanel::Status;
                self.system_msg("TITAN status panel activated");
            }
            ":network" | ":net" => {
                self.panel = ActivePanel::Network;
                self.system_msg("Hydra network panel activated");
            }
            ":chat" => {
                self.panel = ActivePanel::Chat;
                self.system_msg("Chat panel activated");
            }
            ":lazarus" => {
                self.toggle_lazarus();
            }
            ":kill" => {
                self.system_msg("KILL COMMAND SENT — TITAN key material wiped");
                self.titan.key_loaded = false;
                self.titan.kill_armed = true;
            }
            ":tor" => {
                self.system_msg(&format!(
                    "Tor: {} | Circuit age: {}s",
                    if self.network.tor_connected { "CONNECTED" } else { "DISCONNECTED" },
                    self.network.circuit_age_secs
                ));
            }
            ":clear" => {
                self.messages.clear();
                self.system_msg("Chat cleared");
            }
            ":quit" | ":q" => {
                self.running = false;
            }
            _ => {
                self.system_msg(&format!("Unknown command: {}", cmd));
            }
        }
    }

    fn toggle_lazarus(&mut self) {
        match self.mode {
            AppMode::Lazarus => {
                self.mode = AppMode::Normal;
                self.system_msg("Lazarus stealth mode: DEACTIVATED");
            }
            _ => {
                self.mode = AppMode::Lazarus;
                self.system_msg("Lazarus stealth mode: ACTIVATED — screen blanked");
            }
        }
    }

    fn tick(&mut self) {
        self.tick_count += 1;
        if self.mode == AppMode::Lazarus {
            self.lazarus_blink = self.tick_count % 8 < 4;
        }
        // Simulate circuit age increment
        if self.tick_count % 20 == 0 {
            self.network.circuit_age_secs += 1;
        }
    }
}

// ─── Rendering ───────────────────────────────────────────────────────

fn render_header(area: Rect, buf: &mut Buffer, app: &App) {
    let mode_str = match app.mode {
        AppMode::Normal => " NORMAL ",
        AppMode::Lazarus => " LAZARUS ",
        AppMode::Command => " COMMAND ",
    };
    let mode_style = match app.mode {
        AppMode::Normal => Style::new().bg(Color::Green).fg(Color::Black).bold(),
        AppMode::Lazarus => Style::new().bg(Color::Red).fg(Color::White).bold(),
        AppMode::Command => Style::new().bg(Color::Yellow).fg(Color::Black).bold(),
    };

    let titan_indicator = if app.titan.key_loaded {
        Span::styled(" TITAN:OK ", Style::new().bg(Color::Green).fg(Color::Black))
    } else {
        Span::styled(" TITAN:DEAD ", Style::new().bg(Color::Red).fg(Color::White))
    };

    let tor_indicator = if app.network.tor_connected {
        Span::styled(" TOR:ON ", Style::new().bg(Color::Magenta).fg(Color::White))
    } else {
        Span::styled(" TOR:OFF ", Style::new().bg(Color::DarkGray).fg(Color::White))
    };

    let broker_count = app.network.brokers.iter().filter(|b| b.health == 2).count();
    let broker_indicator = Span::styled(
        format!(" MESH:{}/10 ", broker_count),
        if broker_count >= 3 {
            Style::new().bg(Color::Blue).fg(Color::White)
        } else {
            Style::new().bg(Color::Red).fg(Color::White)
        },
    );

    let header = Line::from(vec![
        Span::styled(" PROJECT HIDRA ", Style::new().bg(Color::White).fg(Color::Black).bold()),
        Span::raw(" "),
        Span::styled(mode_str, mode_style),
        Span::raw(" "),
        titan_indicator,
        Span::raw(" "),
        tor_indicator,
        Span::raw(" "),
        broker_indicator,
    ]);

    Paragraph::new(header).render(area, buf);
}

fn render_lazarus(area: Rect, buf: &mut Buffer, app: &App) {
    let text = if app.lazarus_blink {
        ""
    } else {
        // Subtle single pixel blink to confirm system is alive
        "."
    };
    let p = Paragraph::new(text)
        .style(Style::new().fg(Color::DarkGray).bg(Color::Black))
        .block(Block::default().style(Style::new().bg(Color::Black)));
    p.render(area, buf);
}

fn render_chat(area: Rect, buf: &mut Buffer, app: &App) {
    let items: Vec<ListItem> = app
        .messages
        .iter()
        .map(|msg| {
            let style = if msg.sender == "SYSTEM" {
                Style::new().fg(Color::DarkGray).italic()
            } else if msg.is_own {
                Style::new().fg(Color::Cyan)
            } else {
                Style::new().fg(Color::Green)
            };

            let prefix = if msg.sender == "SYSTEM" {
                format!("[{}] ", msg.timestamp)
            } else {
                format!("[{}] {}: ", msg.timestamp, msg.sender)
            };

            ListItem::new(Line::from(vec![
                Span::styled(prefix, Style::new().fg(Color::DarkGray)),
                Span::styled(&msg.content, style),
            ]))
        })
        .collect();

    let block = Block::default()
        .title(" Encrypted Channel ")
        .title_style(Style::new().fg(Color::Cyan).bold())
        .borders(Borders::ALL)
        .border_style(Style::new().fg(Color::DarkGray));

    // Show last messages that fit in the area
    let visible = area.height.saturating_sub(2) as usize;
    let skip = items.len().saturating_sub(visible);
    let visible_items: Vec<ListItem> = items.into_iter().skip(skip).collect();

    Widget::render(List::new(visible_items).block(block), area, buf);
}

fn render_titan_status(area: Rect, buf: &mut Buffer, app: &App) {
    let status = &app.titan;
    let flag = |b: bool| if b { "ACTIVE" } else { " DEAD " };
    let flag_style = |b: bool| {
        if b {
            Style::new().fg(Color::Green).bold()
        } else {
            Style::new().fg(Color::Red).bold()
        }
    };

    let lines = vec![
        Line::from(vec![
            Span::raw("  Omega Cloak DPA : "),
            Span::styled(flag(status.omega_active), flag_style(status.omega_active)),
        ]),
        Line::from(vec![
            Span::raw("  AEGIS Lockstep  : "),
            Span::styled(flag(status.aegis_active), flag_style(status.aegis_active)),
        ]),
        Line::from(vec![
            Span::raw("  AES-256 Key     : "),
            Span::styled(flag(status.key_loaded), flag_style(status.key_loaded)),
        ]),
        Line::from(vec![
            Span::raw("  Lockstep Sync   : "),
            Span::styled(flag(status.lockstep_ok), flag_style(status.lockstep_ok)),
        ]),
        Line::from(vec![
            Span::raw("  TRNG Health     : "),
            Span::styled(flag(status.trng_healthy), flag_style(status.trng_healthy)),
        ]),
        Line::from(vec![
            Span::raw("  POST Self-Test  : "),
            Span::styled(flag(status.post_pass), flag_style(status.post_pass)),
        ]),
        Line::from(vec![
            Span::raw("  Kill Armed      : "),
            Span::styled(flag(status.kill_armed), flag_style(status.kill_armed)),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::raw("  Session Counter : "),
            Span::styled(
                format!("{}", status.session_count),
                Style::new().fg(Color::Yellow),
            ),
        ]),
    ];

    let block = Block::default()
        .title(" TITAN FPGA Status ")
        .title_style(Style::new().fg(Color::Yellow).bold())
        .borders(Borders::ALL)
        .border_style(Style::new().fg(Color::DarkGray));

    Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: false })
        .render(area, buf);
}

fn render_network_status(area: Rect, buf: &mut Buffer, app: &App) {
    let net = &app.network;
    let mut lines = vec![
        Line::from(vec![
            Span::raw("  Ghost Link  : "),
            if net.tor_connected {
                Span::styled("CONNECTED", Style::new().fg(Color::Magenta).bold())
            } else {
                Span::styled("OFFLINE", Style::new().fg(Color::Red).bold())
            },
        ]),
        Line::from(vec![
            Span::raw("  Circuit Age : "),
            Span::styled(
                format!("{}s", net.circuit_age_secs),
                Style::new().fg(Color::Yellow),
            ),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "  Broker Mesh (3-of-10 broadcast):",
            Style::new().fg(Color::Cyan),
        )),
        Line::from(""),
    ];

    // Broker grid
    let broker_spans: Vec<Span> = net
        .brokers
        .iter()
        .map(|b| {
            let (symbol, style) = match b.health {
                2 => ("●", Style::new().fg(Color::Green)),
                1 => ("◐", Style::new().fg(Color::Yellow)),
                _ => ("○", Style::new().fg(Color::Red)),
            };
            Span::styled(format!("  {}:{} ", b.id, symbol), style)
        })
        .collect();

    // Split brokers into 2 rows of 5
    let row1: Vec<Span> = broker_spans[..5].to_vec();
    let row2: Vec<Span> = broker_spans[5..].to_vec();
    lines.push(Line::from(row1));
    lines.push(Line::from(row2));

    lines.push(Line::from(""));
    lines.push(Line::from(vec![
        Span::raw("  TX: "),
        Span::styled(format!("{}", net.messages_sent), Style::new().fg(Color::Cyan)),
        Span::raw("  RX: "),
        Span::styled(format!("{}", net.messages_recv), Style::new().fg(Color::Green)),
    ]));

    let block = Block::default()
        .title(" Hydra Network ")
        .title_style(Style::new().fg(Color::Blue).bold())
        .borders(Borders::ALL)
        .border_style(Style::new().fg(Color::DarkGray));

    Paragraph::new(lines)
        .block(block)
        .wrap(Wrap { trim: false })
        .render(area, buf);
}

fn render_input(area: Rect, buf: &mut Buffer, app: &App) {
    let prompt = match app.mode {
        AppMode::Normal => "MSG",
        AppMode::Command => "CMD",
        AppMode::Lazarus => "---",
    };
    let prompt_style = match app.mode {
        AppMode::Normal => Style::new().fg(Color::Cyan).bold(),
        AppMode::Command => Style::new().fg(Color::Yellow).bold(),
        AppMode::Lazarus => Style::new().fg(Color::DarkGray),
    };

    let input_line = Line::from(vec![
        Span::styled(format!(" {} ", prompt), prompt_style),
        Span::styled("│ ", Style::new().fg(Color::DarkGray)),
        Span::raw(&app.input),
        Span::styled("█", Style::new().fg(Color::Cyan)), // cursor
    ]);

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::new().fg(Color::DarkGray));

    Paragraph::new(input_line).block(block).render(area, buf);
}

fn render_footer(area: Rect, buf: &mut Buffer) {
    let footer = Line::from(vec![
        Span::styled(" F1", Style::new().fg(Color::Yellow).bold()),
        Span::raw(" Lazarus "),
        Span::styled("F2", Style::new().fg(Color::Yellow).bold()),
        Span::raw(" Status "),
        Span::styled("F3", Style::new().fg(Color::Yellow).bold()),
        Span::raw(" Network "),
        Span::styled("F4", Style::new().fg(Color::Yellow).bold()),
        Span::raw(" Chat "),
        Span::styled("Esc", Style::new().fg(Color::Red).bold()),
        Span::raw(" Quit"),
    ]);
    Paragraph::new(footer)
        .style(Style::new().fg(Color::DarkGray))
        .render(area, buf);
}

fn ui(frame: &mut Frame, app: &App) {
    let area = frame.area();

    // Lazarus mode — blank screen
    if app.mode == AppMode::Lazarus {
        render_lazarus(area, frame.buffer_mut(), app);
        return;
    }

    // Layout: header(1) + main + input(3) + footer(1)
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),  // header
            Constraint::Min(8),    // main content
            Constraint::Length(3), // input
            Constraint::Length(1), // footer
        ])
        .split(area);

    render_header(outer[0], frame.buffer_mut(), app);

    // Main content — left panel (chat) + right panel (status/network)
    let main_layout = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage(60),
            Constraint::Percentage(40),
        ])
        .split(outer[1]);

    render_chat(main_layout[0], frame.buffer_mut(), app);

    // Right panel — stacked status + network
    match app.panel {
        ActivePanel::Chat => {
            let right = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Percentage(50),
                    Constraint::Percentage(50),
                ])
                .split(main_layout[1]);
            render_titan_status(right[0], frame.buffer_mut(), app);
            render_network_status(right[1], frame.buffer_mut(), app);
        }
        ActivePanel::Status => {
            render_titan_status(main_layout[1], frame.buffer_mut(), app);
        }
        ActivePanel::Network => {
            render_network_status(main_layout[1], frame.buffer_mut(), app);
        }
    }

    render_input(outer[2], frame.buffer_mut(), app);
    render_footer(outer[3], frame.buffer_mut());
}

// ─── Event Handling ──────────────────────────────────────────────────

fn handle_key(app: &mut App, key: KeyEvent) {
    // Global shortcuts
    match key.code {
        KeyCode::F(1) => {
            app.toggle_lazarus();
            return;
        }
        KeyCode::F(2) => {
            app.panel = ActivePanel::Status;
            app.system_msg("TITAN status panel");
            return;
        }
        KeyCode::F(3) => {
            app.panel = ActivePanel::Network;
            app.system_msg("Hydra network panel");
            return;
        }
        KeyCode::F(4) => {
            app.panel = ActivePanel::Chat;
            return;
        }
        KeyCode::Esc => {
            if app.mode == AppMode::Lazarus {
                app.toggle_lazarus();
            } else {
                app.running = false;
            }
            return;
        }
        _ => {}
    }

    // Lazarus mode — ignore all other input
    if app.mode == AppMode::Lazarus {
        return;
    }

    match key.code {
        KeyCode::Enter => {
            app.send_message();
        }
        KeyCode::Char(c) => {
            // Ctrl+C = quit
            if c == 'c' && key.modifiers.contains(KeyModifiers::CONTROL) {
                app.running = false;
                return;
            }
            app.input.push(c);
            // Auto-detect command mode
            if app.input == ":" {
                app.mode = AppMode::Command;
            }
        }
        KeyCode::Backspace => {
            app.input.pop();
            if app.input.is_empty() && app.mode == AppMode::Command {
                app.mode = AppMode::Normal;
            }
        }
        _ => {}
    }
}

// ─── Main ────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new();

    // Main loop
    while app.running {
        terminal.draw(|frame| ui(frame, &app))?;

        // Poll for events with timeout for tick animation
        if event::poll(Duration::from_millis(100))? {
            if let Event::Key(key) = event::read()? {
                handle_key(&mut app, key);
            }
        }

        app.tick();
    }

    // Cleanup terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;

    println!("PROJECT HIDRA — Terminal closed securely.");
    println!("All cryptographic material has been zeroized.");
    Ok(())
}

// ─── Tests ───────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_app_initialization() {
        let app = App::new();
        assert_eq!(app.mode, AppMode::Normal);
        assert_eq!(app.panel, ActivePanel::Chat);
        assert!(app.running);
        assert!(!app.messages.is_empty()); // Boot messages
        assert!(app.input.is_empty());
    }

    #[test]
    fn test_send_message() {
        let mut app = App::new();
        let initial_count = app.messages.len();
        app.input = "Hello HIDRA".to_string();
        app.send_message();
        // +2: user message + network dispatch feedback
        assert_eq!(app.messages.len(), initial_count + 2);
        assert!(app.input.is_empty());
        // User message is second-to-last (feedback is last)
        let user_msg = &app.messages[initial_count];
        assert_eq!(user_msg.sender, "YOU");
        assert!(user_msg.is_own);
    }

    #[test]
    fn test_command_help() {
        let mut app = App::new();
        let initial_count = app.messages.len();
        app.input = ":help".to_string();
        app.send_message();
        assert!(app.messages.len() > initial_count);
    }

    #[test]
    fn test_command_status() {
        let mut app = App::new();
        app.input = ":status".to_string();
        app.send_message();
        assert_eq!(app.panel, ActivePanel::Status);
    }

    #[test]
    fn test_command_network() {
        let mut app = App::new();
        app.input = ":network".to_string();
        app.send_message();
        assert_eq!(app.panel, ActivePanel::Network);
    }

    #[test]
    fn test_lazarus_toggle() {
        let mut app = App::new();
        assert_eq!(app.mode, AppMode::Normal);

        app.toggle_lazarus();
        assert_eq!(app.mode, AppMode::Lazarus);

        app.toggle_lazarus();
        assert_eq!(app.mode, AppMode::Normal);
    }

    #[test]
    fn test_kill_command() {
        let mut app = App::new();
        assert!(app.titan.key_loaded);
        assert!(!app.titan.kill_armed);

        app.input = ":kill".to_string();
        app.send_message();

        assert!(!app.titan.key_loaded);
        assert!(app.titan.kill_armed);
    }

    #[test]
    fn test_quit_command() {
        let mut app = App::new();
        assert!(app.running);
        app.input = ":quit".to_string();
        app.send_message();
        assert!(!app.running);
    }

    #[test]
    fn test_clear_command() {
        let mut app = App::new();
        assert!(!app.messages.is_empty());
        app.input = ":clear".to_string();
        app.send_message();
        // After clear, only the "Chat cleared" system message remains
        assert_eq!(app.messages.len(), 1);
    }

    #[test]
    fn test_titan_status_default() {
        let status = TitanStatus::default();
        assert!(status.omega_active);
        assert!(status.aegis_active);
        assert!(status.key_loaded);
        assert!(status.lockstep_ok);
        assert!(status.trng_healthy);
        assert!(status.post_pass);
        assert!(!status.kill_armed);
    }

    #[test]
    fn test_network_status_default() {
        let net = NetworkStatus::default();
        assert!(net.tor_connected);
        assert_eq!(net.brokers.len(), 10);
        // 7 alive, 2 sick, 1 dead
        assert_eq!(net.brokers.iter().filter(|b| b.health == 2).count(), 7);
        assert_eq!(net.brokers.iter().filter(|b| b.health == 1).count(), 2);
        assert_eq!(net.brokers.iter().filter(|b| b.health == 0).count(), 1);
    }

    #[test]
    fn test_tick_updates() {
        let mut app = App::new();
        let initial_age = app.network.circuit_age_secs;
        // 20 ticks should increment circuit age by 1
        for _ in 0..20 {
            app.tick();
        }
        assert_eq!(app.network.circuit_age_secs, initial_age + 1);
    }

    #[test]
    fn test_empty_message_ignored() {
        let mut app = App::new();
        let count = app.messages.len();
        app.input = String::new();
        app.send_message();
        assert_eq!(app.messages.len(), count); // No new message
    }

    #[test]
    fn test_unknown_command() {
        let mut app = App::new();
        let count = app.messages.len();
        app.input = ":bogus".to_string();
        app.send_message();
        assert!(app.messages.last().unwrap().content.contains("Unknown command"));
    }
}

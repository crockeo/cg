use ratatui::Frame;
use ratatui::crossterm::event::{self, KeyCode, KeyModifiers};
use ratatui::style::Stylize;
use ratatui::widgets::{Block, Paragraph};
use std::sync::mpsc::{Sender, channel};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Copy, Clone, Debug)]
enum Event {
    KeyEvent(event::KeyEvent),
}

struct App {
    stack: Vec<Box<dyn State>>,
}

enum StackOp {
    Null,
    Consume,
    Pop,
    Push(Box<dyn State>),
    Replace(Box<dyn State>),
}

trait State {
    fn handle(&mut self, event: Event) -> Result<StackOp>;
    fn render(&self, frame: &mut Frame);
}

struct Root {}

impl State for Root {
    fn handle(&mut self, event: Event) -> Result<StackOp> {
        use Event::*;
        Ok(match event {
            KeyEvent(key_evt)
                if key_evt.code == KeyCode::Char('c')
                    && key_evt.modifiers == KeyModifiers::CONTROL =>
            {
                StackOp::Pop
            }
            _ => StackOp::Consume,
        })
    }

    fn render(&self, frame: &mut Frame) {
        frame.render_widget(Paragraph::new("testing testing"), frame.area())
    }
}

fn main() -> Result<()> {
    ratatui::run(|terminal| {
        let (tx, rx) = channel::<Event>();

        {
            let tx = tx.clone();
            std::thread::spawn(move || input_main(tx));
        }

        let mut stack: Vec<Box<dyn State>> = vec![Box::new(Root {})];
        while stack.len() > 0 {
            terminal.draw(|frame| {
                for state in stack.iter() {
                    state.render(frame);
                }
            })?;

            let evt = rx.recv()?;
            let stack_len = stack.len();
            for i in 0..stack_len {
                let stack_op = stack[stack_len - i - 1].handle(evt)?;
                match stack_op {
                    StackOp::Null => {
                        // Intentionally do not block from the parent state from handling.
                        // We just pass it on to the thing next in the stack.
                    }
                    StackOp::Consume => {
                        break;
                    }
                    StackOp::Pop => {
                        stack.pop();
                        break;
                    }
                    StackOp::Push(new_state) => {
                        stack.push(new_state);
                        break;
                    }
                    StackOp::Replace(new_state) => {
                        stack.pop();
                        stack.push(new_state);
                        break;
                    }
                }
            }
        }
        Ok(())
    })
}

fn input_main(tx: Sender<Event>) {
    loop {
        let Ok(evt) = event::read() else {
            continue;
        };
        let Some(key_evt) = evt.as_key_press_event() else {
            continue;
        };
        let _ = tx.send(Event::KeyEvent(key_evt));
    }
}

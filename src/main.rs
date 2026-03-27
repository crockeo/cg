use ratatui::Frame;
use ratatui::style::Stylize;
use ratatui::widgets::{Block, Paragraph};
use std::sync::mpsc::channel;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

enum Event {}

struct App {
    stack: Vec<Box<dyn State>>,
}

enum StackOp {
    Null,
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
        Ok(StackOp::Null)
    }

    fn render(&self, frame: &mut Frame) {}
}

fn main() -> Result<()> {
    ratatui::run(|terminal| {
        let (tx, rx) = channel::<Event>();

        let mut stack: Vec<Box<dyn State>> = vec![Box::new(Root {})];
        while stack.len() > 0 {
            terminal.draw(|frame| {
                for state in stack.iter() {
                    state.render(frame);
                }
            })?;

            let stack_len = stack.len();
            let stack_op = stack[stack_len - 1].handle(rx.recv()?)?;
            match stack_op {
                StackOp::Null => {}
                StackOp::Pop => {
                    stack.pop();
                }
                StackOp::Push(new_state) => {
                    stack.push(new_state);
                }
                StackOp::Replace(new_state) => {
                    stack.pop();
                    stack.push(new_state);
                }
            }
        }
        Ok(())
    })
}

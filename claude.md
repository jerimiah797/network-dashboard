# Network Dashboard - Development Notes

## Server Commands

**Kill and restart the Flask server:**
```bash
pkill -9 -f "python.*app.py" 2>/dev/null; sleep 1 && source venv/bin/activate && python app.py
```

Run with `run_in_background: true` when using from Claude.

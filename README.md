# AI Explorer

A Godot 4.2 project featuring an AI-controlled character that explores 3D environments using Groq API for decision making.

## Features
- Free 3D movement and exploration
- Environment sensing with raycasts
- Path memory and learning
- Auto-switching between local and Groq API
- Debug logging and visualization

## Setup
1. Create the scene structure:
```
Player (CharacterBody3D)
├── CameraManager/Arm/Camera3D
├── CollisionShapeBody
├── CollisionShapeRay
├── Body
└── Timer
```

2. Set your API key in Player.gd:
```gdscript
const API_KEY = "your_groq_api_key"
```

## Usage
Run the scene and the AI will automatically:
- Explore the environment
- Avoid obstacles
- Record its path
- Learn from surroundings


# Kamal Napper

**Automatically manage idle Rails applications deployed with Kamal to optimize server resources**

Kamal Napper is a lightweight daemon that monitors your Rails applications deployed via Kamal and automatically stops idle containers to free up memory and CPU for active applications. When new requests arrive, it seamlessly starts the containers back up using Kamal's built-in maintenance mode to provide a smooth user experience.

## 🚀 Key Features

- **Automatic Scaling**: Stops idle Rails containers and starts them on-demand
- **Resource Optimization**: Reduce memory and CPU usage by running only active applications
- **Seamless Experience**: Uses Kamal's maintenance mode with a spinner page during startup
- **Kamal Native**: Built specifically for Kamal 2 deployments
- **Reliable**: Includes retry logic, health checks, and state persistence
- **Lightweight**: Minimal resource usage and dependencies
- **Multi-App Support**: Manage multiple Rails applications on a single server

## 🎯 Why Kamal Napper?

Running multiple Rails applications on a single EC2 instance is efficient, but keeping all containers running 24/7 wastes valuable server resources. Kamal Napper solves this by:

1. **Monitoring traffic** via kamal-proxy access logs
2. **Stopping containers** after a configurable idle period
3. **Starting containers** automatically when requests arrive
4. **Showing a spinner page** during the brief startup time

This approach can significantly improve resource utilization while maintaining a professional user experience.

## 📦 Installation

Add this line to your application's Gemfile:

```ruby
gem 'kamal-napper'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install kamal-napper
```

## ⚙️ Configuration

Create a configuration file at `config/kamal_napper.yml`:

```yaml
# Timing configuration
idle_timeout: 900      # seconds before stopping (15 minutes)
poll_interval: 10      # check interval in seconds
startup_timeout: 60    # max time to wait for startup
max_retries: 3         # retry failed commands
```

### Configuration Options

- **`idle_timeout`**: How long (in seconds) to wait before stopping an idle container
- **`poll_interval`**: How often to check for activity and update app states
- **`startup_timeout`**: Maximum time to wait for a container to start before timing out
- **`max_retries`**: Number of times to retry failed Kamal commands

### Automatic Application Discovery

Kamal Napper automatically discovers all Kamal-deployed applications through multiple methods:

1. **kamal-proxy Access Logs**: Monitors incoming requests to detect active hostnames
2. **Docker Container Labels**: Scans running containers for Kamal service labels
3. **Kamal Metadata**: Uses Kamal commands to list deployed applications

No manual configuration of applications is required - Kamal Napper will automatically detect and manage all your Kamal deployments.

## 🎯 Usage

### Basic Commands

Start the daemon:
```bash
kamal-napper start
```

Check application status:
```bash
kamal-napper status
```

Manually wake up an application:
```bash
kamal-napper wake myapp
```

Stop all applications:
```bash
kamal-napper stop-all
```

### Typical Workflow

1. **Deploy your Rails apps** with Kamal as usual
2. **Deploy Kamal Napper** to the same server
3. **Monitor logs** to see automatic scaling in action

The daemon will automatically discover your Kamal applications and continuously monitor them, handling the start/stop lifecycle without any manual configuration.

## 🐳 Deployment

Kamal Napper is designed to be deployed alongside your Rails applications using Kamal itself.

### 1. Create a Dockerfile

```dockerfile
FROM ruby:3.3-slim

WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile* ./
RUN bundle install --without development test

COPY . .

# Create state directory
RUN mkdir -p /var/lib/kamal-napper

CMD ["bin/kamal-napper", "start"]
```

### 2. Configure Kamal deployment

Create a `kamal.yml` file for Kamal Napper:

```yaml
service: kamal-napper
image: your-docker-repo/kamal-napper

servers:
  - deploy@your-ec2-instance

roles:
  - napper

env:
  IDLE_TIMEOUT: 900
  LOG_PATH: /var/log/kamal-proxy/access.log
  STATE_FILE: /var/lib/kamal-napper/state.json

volumes:
  - "/var/log/kamal-proxy:/var/log/kamal-proxy:ro"
  - "/var/lib/kamal-napper:/var/lib/kamal-napper"
  - "/var/run/docker.sock:/var/run/docker.sock"
```

### 3. Deploy

```bash
kamal deploy
```

## 🔧 How It Works

Kamal Napper operates through a simple but effective process:

### Application Discovery

Kamal Napper automatically discovers applications through:

1. **Docker Container Scanning**: Finds containers with Kamal service labels
2. **kamal-proxy Log Analysis**: Extracts hostnames from proxy access logs
3. **Kamal Command Integration**: Uses `kamal app list` and similar commands
4. **Dynamic Detection**: Continuously discovers new deployments without restart

### Application States

Each managed application can be in one of four states:

- **`:running`** - Container is up and serving requests
- **`:idle`** - No recent requests detected (transitional state)
- **`:stopped`** - Container is stopped to free up memory and CPU
- **`:starting`** - Container is starting up after a request

### Monitoring Process

1. **Application Discovery**: Automatically detects all Kamal-deployed applications
2. **Request Detection**: Monitors kamal-proxy access logs for incoming requests
3. **State Tracking**: Maintains timestamps of last activity for each application
4. **Automatic Scaling**: Stops containers after the idle timeout period
5. **On-Demand Starting**: Starts containers when new requests are detected
6. **Health Checking**: Verifies containers are ready before removing maintenance mode

### Safety Features

- **Retry Logic**: Failed Kamal commands are retried with exponential backoff
- **Startup Protection**: Prevents multiple simultaneous start attempts
- **Timeout Handling**: Resets state if containers fail to start within the timeout
- **State Persistence**: Survives daemon restarts without losing application state
- **Graceful Maintenance**: Uses Kamal's maintenance mode with a professional spinner page

## 📋 Requirements

- **Ruby**: 3.3.0 or higher
- **Kamal**: 2.0 or higher
- **Docker**: Access to Docker socket for container management
- **Linux**: Designed for Linux-based deployments (Ubuntu, Debian, etc.)

### Dependencies

- `thor` (~> 1.0) - CLI framework
- `yaml` (~> 0.2) - Configuration parsing

## 🤝 Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/justinpaulson/kamal-napper.

### Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/justinpaulson/kamal-napper.git
   cd kamal-napper
   ```

2. Install dependencies:
   ```bash
   bundle install
   ```

3. Run tests:
   ```bash
   bundle exec rspec
   ```

### Guidelines

- Follow Ruby style conventions
- Add tests for new features
- Update documentation as needed
- Keep the codebase simple and maintainable

## 📄 License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## 🙏 Acknowledgments

- Built for [Kamal](https://kamal-deploy.org/) by 37signals
- Inspired by the need to optimize resource usage for multiple Rails applications
- Thanks to the Ruby and Rails community for their excellent tools and documentation

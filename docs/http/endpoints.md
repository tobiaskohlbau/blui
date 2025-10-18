# HTTP Endpoints

Provided by `src/main.zig` using `pkg/http/Server.zig`:

- **GET /api/version**
  - Returns API and server version as JSON
  - Example response:
    ```json
    {
      "api": "0.1",
      "server": "1.3.10",
      "text": "OctoPrint 1.3.10"
    }
    ```

- **GET /api/printer/status**
  - Returns current printer temperatures as JSON
  - Example response:
    ```json
    {
      "temperature": {
        "bed": 45.2,
        "nozzle": 205.1
      }
    }
    ```

- **GET /api/printer/led/chamber?state=on|off**
  - Publishes an MQTT command to control chamber LED and returns "ok"

- **POST /api/files/local**
  - Content-Type: multipart/form-data; boundary=...
  - Fields:
    - `file`: file content
    - `print`: optional boolean string ("true" to start printing after upload)
  - Response: "ok" on success

- **GET /api/webcam.jpg**
  - Returns latest webcam JPEG image

- **Static assets**
  - All other paths are served from embedded UI; falls back to `200.html` if present

pub const Status = struct {
    pub const Temperature = struct {
        bed: f64,
        nozzle: f64,
    };

    temperature: Temperature,
    image: []u8,
};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Coordinate {
    pub lat: f64,
    pub lng: f64,
}

impl Coordinate {
    pub fn valid(self) -> bool {
        self.lat.is_finite()
            && self.lng.is_finite()
            && (-90.0..=90.0).contains(&self.lat)
            && (-180.0..=180.0).contains(&self.lng)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Driver {
    pub id: String,
    pub name: String,
    pub active: bool,
    pub capacity: i32,
    pub location: Option<Coordinate>,
    pub location_updated_at: Option<i64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryStatus {
    Pending,
    Assigned,
    PickedUp,
    Delivered,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Delivery {
    pub id: String,
    pub shop_name: String,
    pub pickup_address: String,
    pub pickup: Coordinate,
    pub dropoff_address: String,
    pub dropoff: Coordinate,
    pub ready_at: i64,
    pub deadline_at: i64,
    pub load_units: i32,
    pub max_ride_seconds: i64,
    pub status: DeliveryStatus,
    pub driver_id: Option<String>,
    pub created_at: i64,
    pub picked_up_at: Option<i64>,
    pub delivered_at: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewDelivery {
    pub shop_name: String,
    pub pickup_address: String,
    pub pickup: Coordinate,
    pub dropoff_address: String,
    pub dropoff: Coordinate,
    pub ready_at: i64,
    pub deadline_at: i64,
    pub load_units: i32,
    pub max_ride_seconds: i64,
}

impl NewDelivery {
    pub fn validate(&self) -> Result<(), &'static str> {
        for value in [&self.shop_name, &self.pickup_address, &self.dropoff_address] {
            if value.trim().is_empty() || value.chars().count() > 240 {
                return Err("Names and addresses must contain 1–240 characters");
            }
        }
        if !self.pickup.valid() || !self.dropoff.valid() {
            return Err("Coordinates must be finite latitude/longitude values");
        }
        // Bounded timestamps make arithmetic safe and reject accidental milliseconds.
        if self.ready_at < 0 || self.deadline_at > 32_503_680_000 {
            return Err("Timestamps must be Unix seconds between 1970 and 3000");
        }
        if self.deadline_at < self.ready_at {
            return Err("Deadline must be at or after readiness");
        }
        if !(1..=8).contains(&self.load_units) {
            return Err("Load must be between 1 and 8 units");
        }
        if !(60..=7200).contains(&self.max_ride_seconds) {
            return Err("Maximum ride time must be between 60 and 7200 seconds");
        }
        Ok(())
    }

    pub fn into_delivery(self, now: i64) -> Delivery {
        Delivery {
            id: uuid::Uuid::new_v4().to_string(),
            shop_name: self.shop_name.trim().to_owned(),
            pickup_address: self.pickup_address.trim().to_owned(),
            pickup: self.pickup,
            dropoff_address: self.dropoff_address.trim().to_owned(),
            dropoff: self.dropoff,
            ready_at: self.ready_at,
            deadline_at: self.deadline_at,
            load_units: self.load_units,
            max_ride_seconds: self.max_ride_seconds,
            status: DeliveryStatus::Pending,
            driver_id: None,
            created_at: now,
            picked_up_at: None,
            delivered_at: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum StopKind {
    Pickup,
    Dropoff,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct StopKey {
    pub delivery_id: String,
    pub kind: StopKind,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteStop {
    pub delivery_id: String,
    pub kind: StopKind,
    pub address: String,
    pub coordinate: Coordinate,
    pub arrival_at: i64,
    pub departure_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Route {
    pub driver_id: String,
    pub stops: Vec<RouteStop>,
    pub travel_seconds: i64,
    pub finish_at: i64,
    pub feasible: bool,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Suggestion {
    pub driver_id: String,
    pub incremental_travel_seconds: i64,
    pub route: Route,
}

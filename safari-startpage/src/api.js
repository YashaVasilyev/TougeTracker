// Weather via Open-Meteo (no API key required).
//
// The last successful response is kept in localStorage and rendered on the
// first paint, with a background fetch replacing it. Weather changes slowly, so
// showing a value from a few minutes ago beats showing a spinner.

const WMO = {
  0: ['Clear', '☀️'],
  1: ['Mostly clear', '🌤️'],
  2: ['Partly cloudy', '⛅'],
  3: ['Overcast', '☁️'],
  45: ['Fog', '🌫️'],
  48: ['Freezing fog', '🌫️'],
  51: ['Light drizzle', '🌦️'],
  53: ['Drizzle', '🌦️'],
  55: ['Heavy drizzle', '🌧️'],
  61: ['Light rain', '🌦️'],
  63: ['Rain', '🌧️'],
  65: ['Heavy rain', '🌧️'],
  71: ['Light snow', '🌨️'],
  73: ['Snow', '🌨️'],
  75: ['Heavy snow', '❄️'],
  80: ['Showers', '🌦️'],
  81: ['Showers', '🌧️'],
  82: ['Violent showers', '⛈️'],
  95: ['Thunderstorm', '⛈️'],
  96: ['Thunderstorm, hail', '⛈️'],
  99: ['Thunderstorm, hail', '⛈️'],
};

export function describeWeather(code) {
  return WMO[code] ?? ['Unknown', '🌡️'];
}

const WEATHER_KEY = 'startpage.weather.v1';
const WEATHER_MAX_AGE_MS = 30 * 60 * 1000;

// Synchronous: the cached reading (even a stale one) is available on the very
// first render, so the card has numbers immediately.
export function loadCachedWeather(key) {
  try {
    const raw = localStorage.getItem(`${WEATHER_KEY}.${key}`);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function saveCachedWeather(key, data) {
  try {
    localStorage.setItem(`${WEATHER_KEY}.${key}`, JSON.stringify(data));
  } catch {
    /* private mode — weather just won't be pre-warmed */
  }
}

function weatherKey({ lat, lon, units }) {
  return `${lat.toFixed(2)},${lon.toFixed(2)},${units}`;
}

export async function fetchWeather({ lat, lon, units }) {
  const imperial = units === 'imperial';
  const params = new URLSearchParams({
    latitude: String(lat),
    longitude: String(lon),
    current: 'temperature_2m,apparent_temperature,weather_code,is_day',
    daily: 'weather_code,temperature_2m_max,temperature_2m_min',
    temperature_unit: imperial ? 'fahrenheit' : 'celsius',
    wind_speed_unit: imperial ? 'mph' : 'kmh',
    timezone: 'auto',
    forecast_days: '5',
  });

  const res = await fetch(`https://api.open-meteo.com/v1/forecast?${params}`);
  if (!res.ok) throw new Error(`Weather API ${res.status}`);
  const data = await res.json();

  const days = (data.daily?.time ?? []).map((t, i) => ({
    date: t,
    code: data.daily.weather_code[i],
    high: data.daily.temperature_2m_max[i],
    low: data.daily.temperature_2m_min[i],
  }));

  const key = weatherKey({ lat, lon, units });
  saveCachedWeather(key, {
    at: Date.now(),
    data: {
      temp: Math.round(data.current.temperature_2m),
      feelsLike: Math.round(data.current.apparent_temperature),
      code: data.current.weather_code,
      isDay: data.current.is_day === 1,
      high: days[0]?.high,
      low: days[0]?.low,
      unit: imperial ? '°F' : '°C',
      speedUnit: imperial ? 'mph' : 'km/h',
      days,
    },
  });

  return {
    temp: Math.round(data.current.temperature_2m),
    feelsLike: Math.round(data.current.apparent_temperature),
    code: data.current.weather_code,
    isDay: data.current.is_day === 1,
    high: days[0]?.high,
    low: days[0]?.low,
    unit: imperial ? '°F' : '°C',
    speedUnit: imperial ? 'mph' : 'km/h',
    days,
  };
}

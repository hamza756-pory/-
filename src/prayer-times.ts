// Prayer times data with Iqama times
export interface CityPrayerTimes {
  fajr: { adhan: string; iqama: string };
  sunrise: string;
  dhuhr: { adhan: string; iqama: string };
  asr: { adhan: string; iqama: string };
  maghrib: { adhan: string; iqama: string };
  isha: { adhan: string; iqama: string };
}

export interface QiblaAngle {
  [key: string]: number;
}

export const prayerTimesData: { [key: string]: CityPrayerTimes } = {
  cairo: {
    fajr: { adhan: "05:30", iqama: "05:45" },
    sunrise: "06:45",
    dhuhr: { adhan: "12:15", iqama: "12:30" },
    asr: { adhan: "15:30", iqama: "15:45" },
    maghrib: { adhan: "17:45", iqama: "17:46" },
    isha: { adhan: "19:15", iqama: "19:30" }
  },
  riyadh: {
    fajr: { adhan: "04:45", iqama: "05:00" },
    sunrise: "06:00",
    dhuhr: { adhan: "11:45", iqama: "12:00" },
    asr: { adhan: "14:30", iqama: "14:45" },
    maghrib: { adhan: "17:15", iqama: "17:16" },
    isha: { adhan: "18:45", iqama: "19:00" }
  },
  dubai: {
    fajr: { adhan: "05:00", iqama: "05:15" },
    sunrise: "06:15",
    dhuhr: { adhan: "12:00", iqama: "12:15" },
    asr: { adhan: "15:15", iqama: "15:30" },
    maghrib: { adhan: "17:30", iqama: "17:31" },
    isha: { adhan: "19:00", iqama: "19:15" }
  },
  beirut: {
    fajr: { adhan: "05:15", iqama: "05:30" },
    sunrise: "06:30",
    dhuhr: { adhan: "12:15", iqama: "12:30" },
    asr: { adhan: "15:30", iqama: "15:45" },
    maghrib: { adhan: "17:45", iqama: "17:46" },
    isha: { adhan: "19:15", iqama: "19:30" }
  },
  baghdad: {
    fajr: { adhan: "05:00", iqama: "05:15" },
    sunrise: "06:15",
    dhuhr: { adhan: "12:00", iqama: "12:15" },
    asr: { adhan: "15:15", iqama: "15:30" },
    maghrib: { adhan: "17:30", iqama: "17:31" },
    isha: { adhan: "19:00", iqama: "19:15" }
  },
  istanbul: {
    fajr: { adhan: "05:45", iqama: "06:00" },
    sunrise: "07:15",
    dhuhr: { adhan: "12:30", iqama: "12:45" },
    asr: { adhan: "15:45", iqama: "16:00" },
    maghrib: { adhan: "18:00", iqama: "18:01" },
    isha: { adhan: "19:30", iqama: "19:45" }
  },
  karachi: {
    fajr: { adhan: "05:20", iqama: "05:35" },
    sunrise: "06:35",
    dhuhr: { adhan: "12:10", iqama: "12:25" },
    asr: { adhan: "15:25", iqama: "15:40" },
    maghrib: { adhan: "17:40", iqama: "17:41" },
    isha: { adhan: "19:10", iqama: "19:25" }
  },
  lahore: {
    fajr: { adhan: "05:25", iqama: "05:40" },
    sunrise: "06:40",
    dhuhr: { adhan: "12:15", iqama: "12:30" },
    asr: { adhan: "15:30", iqama: "15:45" },
    maghrib: { adhan: "17:45", iqama: "17:46" },
    isha: { adhan: "19:15", iqama: "19:30" }
  },
  kuala_lumpur: {
    fajr: { adhan: "06:00", iqama: "06:15" },
    sunrise: "07:15",
    dhuhr: { adhan: "12:30", iqama: "12:45" },
    asr: { adhan: "15:45", iqama: "16:00" },
    maghrib: { adhan: "18:00", iqama: "18:01" },
    isha: { adhan: "19:30", iqama: "19:45" }
  },
  cape_town: {
    fajr: { adhan: "04:45", iqama: "05:00" },
    sunrise: "06:00",
    dhuhr: { adhan: "12:00", iqama: "12:15" },
    asr: { adhan: "15:15", iqama: "15:30" },
    maghrib: { adhan: "17:30", iqama: "17:31" },
    isha: { adhan: "19:00", iqama: "19:15" }
  }
};

// Qibla direction angles for different cities
export const qiblaAngles: QiblaAngle = {
  cairo: 135,
  riyadh: 165,
  dubai: 145,
  beirut: 125,
  baghdad: 130,
  istanbul: 110,
  karachi: 95,
  lahore: 93,
  kuala_lumpur: 290,
  cape_town: 45
};

// Function to convert time string to minutes from midnight
export function timeToMinutes(timeStr: string): number {
  const timeParts = timeStr.split(':');
  const hours = parseInt(timeParts[0] || '0');
  const minutes = parseInt(timeParts[1] || '0');
  return hours * 60 + minutes;
}

// Function to get current time in minutes
export function getCurrentTimeInMinutes(): number {
  const now = new Date();
  return now.getHours() * 60 + now.getMinutes();
}

// Function to calculate remaining time until next prayer
export function getTimeRemaining(nextPrayerTime: string): string {
  const currentTime = getCurrentTimeInMinutes();
  const prayerTime = timeToMinutes(nextPrayerTime);

  // If prayer time has passed today, calculate for next day
  let diff = prayerTime - currentTime;
  if (diff < 0) {
    diff += 24 * 60; // Add 24 hours in minutes
  }

  const hours = Math.floor(diff / 60);
  const minutes = diff % 60;

  return `${hours}h ${minutes}m`;
}

// Function to get remaining time in seconds for countdown
export function getTimeRemainingInSeconds(targetTime: string): number {
  const now = new Date();
  const timeParts = targetTime.split(':');
  const targetHours = parseInt(timeParts[0] || '0');
  const targetMinutes = parseInt(timeParts[1] || '0');
  
  // Create a date object for the target time today
  const targetDate = new Date(now);
  targetDate.setHours(targetHours, targetMinutes, 0, 0);
  
  // If target time has passed today, set it to tomorrow
  if (targetDate <= now) {
    targetDate.setDate(targetDate.getDate() + 1);
  }
  
  const diffMs = targetDate.getTime() - now.getTime();
  return Math.floor(diffMs / 1000);
}

// Function to format seconds into HH:MM:SS
export function formatTime(seconds: number): string {
  const hrs = Math.floor(seconds / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;
  
  return `${hrs.toString().padStart(2, '0')}:${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
}

// Hijri date conversion (simplified calculation)
export function toHijri(date: Date): string {
  // Simplified Hijri calculation
  const hijriYear = Math.floor((date.getFullYear() - 622) * 1.030688825);
  const monthNames = [
    'Muharram', 'Safar', 'Rabi\' al-Awwal', 'Rabi\' al-Thani',
    'Jumada al-Awwal', 'Jumada al-Thani', 'Rajab', 'Sha\'ban',
    'Ramadan', 'Shawwal', 'Dhu al-Qi\'dah', 'Dhu al-Hijjah'
  ];
  const hijriMonth = monthNames[date.getMonth()];
  const hijriDay = date.getDate();

  return `${hijriDay} ${hijriMonth} ${hijriYear} AH`;
}
import { 
  prayerTimesData, 
  qiblaAngles, 
  getTimeRemaining, 
  getTimeRemainingInSeconds, 
  formatTime, 
  toHijri 
} from './prayer-times';

class PrayerTimesApp {
  private countdownTimers: { [key: string]: number } = {};
  
  constructor() {
    this.initializeEventListeners();
    this.refreshAll();
    
    // Update all data every minute
    setInterval(() => {
      this.refreshAll();
    }, 60000);
  }
  
  private initializeEventListeners(): void {
    // City selection change
    const citySelect = document.getElementById('city-select') as HTMLSelectElement;
    citySelect.addEventListener('change', () => {
      this.refreshAll();
    });
    
    // Refresh button click
    const refreshBtn = document.getElementById('refresh-btn') as HTMLButtonElement;
    refreshBtn.addEventListener('click', () => {
      this.refreshAll();
    });
    
    // Calculation method change
    const methodSelect = document.getElementById('method-select') as HTMLSelectElement;
    methodSelect.addEventListener('change', () => {
      this.refreshAll();
    });
    
    // Juristic method change
    const juristicSelect = document.getElementById('juristic-select') as HTMLSelectElement;
    juristicSelect.addEventListener('change', () => {
      this.refreshAll();
    });
  }
  
  private refreshAll(): void {
    this.updatePrayerTimes();
    this.updateDate();
    this.updateQiblaDirection();
    this.updateLastUpdateTime();
  }
  
  private updatePrayerTimes(): void {
    const city = (document.getElementById('city-select') as HTMLSelectElement).value;
    const times = prayerTimesData[city];
    
    if (!times) {
      console.error(`No prayer times found for city: ${city}`);
      return;
    }
    
    // Update Adhan times
    (document.getElementById('fajr-time') as HTMLElement).textContent = times.fajr.adhan;
    (document.getElementById('sunrise-time') as HTMLElement).textContent = times.sunrise;
    (document.getElementById('dhuhr-time') as HTMLElement).textContent = times.dhuhr.adhan;
    (document.getElementById('asr-time') as HTMLElement).textContent = times.asr.adhan;
    (document.getElementById('maghrib-time') as HTMLElement).textContent = times.maghrib.adhan;
    (document.getElementById('isha-time') as HTMLElement).textContent = times.isha.adhan;
    
    // Update Iqama times
    (document.getElementById('fajr-iqama') as HTMLElement).textContent = `Iqama: ${times.fajr.iqama}`;
    (document.getElementById('dhuhr-iqama') as HTMLElement).textContent = `Iqama: ${times.dhuhr.iqama}`;
    (document.getElementById('asr-iqama') as HTMLElement).textContent = `Iqama: ${times.asr.iqama}`;
    (document.getElementById('maghrib-iqama') as HTMLElement).textContent = `Iqama: ${times.maghrib.iqama}`;
    (document.getElementById('isha-iqama') as HTMLElement).textContent = `Iqama: ${times.isha.iqama}`;
    
    // Clear existing countdown timers
    Object.values(this.countdownTimers).forEach(timer => clearInterval(timer));
    this.countdownTimers = {};
    
    // Calculate next prayer and update countdowns
    const currentTime = new Date();
    const currentHours = currentTime.getHours();
    const currentMinutes = currentTime.getMinutes();
    const currentTotalMinutes = currentHours * 60 + currentMinutes;
    
    // Define prayers to check (excluding sunrise)
    const prayers = [
      { name: 'fajr', time: times.fajr.iqama },
      { name: 'dhuhr', time: times.dhuhr.iqama },
      { name: 'asr', time: times.asr.iqama },
      { name: 'maghrib', time: times.maghrib.iqama },
      { name: 'isha', time: times.isha.iqama }
    ];
    
    // Find next prayer
    let nextPrayer: string | null = null;
    for (const prayer of prayers) {
      const timeParts = prayer.time.split(':');
      const hours = parseInt(timeParts[0] || '0');
      const minutes = parseInt(timeParts[1] || '0');
      const prayerTotalMinutes = hours * 60 + minutes;
      
      // Check if prayer time is ahead of current time
      if (prayerTotalMinutes > currentTotalMinutes) {
        nextPrayer = prayer.name;
        break;
      }
    }
    
    // If no next prayer found (meaning all prayers passed for today), use Fajr of next day
    if (!nextPrayer) {
      nextPrayer = 'fajr';
    }
    
    // Set countdown timers for each prayer
    prayers.forEach(prayer => {
      const countdownElement = document.getElementById(`${prayer.name}-countdown`) as HTMLElement;
      if (!countdownElement) return;
      
      // Initial update
      const remainingSeconds = getTimeRemainingInSeconds(prayer.time);
      countdownElement.textContent = formatTime(remainingSeconds);
      
      // Update the countdown every second
      if (this.countdownTimers[prayer.name]) {
        clearInterval(this.countdownTimers[prayer.name]);
      }
      
      this.countdownTimers[prayer.name] = window.setInterval(() => {
        const remaining = getTimeRemainingInSeconds(prayer.time);
        countdownElement.textContent = formatTime(remaining);
        
        // Highlight the next prayer
        if (prayer.name === nextPrayer) {
          countdownElement.style.color = '#ff6b6b';
          countdownElement.style.fontWeight = 'bold';
        } else {
          countdownElement.style.color = '#ccc';
          countdownElement.style.fontWeight = 'normal';
        }
      }, 1000);
    });
  }
  
  private updateDate(): void {
    const now = new Date();
    
    // Gregorian date
    const gregorianOptions: Intl.DateTimeFormatOptions = { 
      year: 'numeric', 
      month: 'long', 
      day: 'numeric', 
      weekday: 'long' 
    };
    const gregorianDate = now.toLocaleDateString('en-US', gregorianOptions);
    (document.getElementById('gregorian-date') as HTMLElement).textContent = `Gregorian Date: ${gregorianDate}`;
    
    // Hijri date
    const hijriDate = toHijri(now);
    (document.getElementById('hijri-date') as HTMLElement).textContent = `Hijri Date: ${hijriDate}`;
  }
  
  private updateQiblaDirection(): void {
    const city = (document.getElementById('city-select') as HTMLSelectElement).value;
    const angle = qiblaAngles[city] || 0;
    const indicator = document.getElementById('qibla-indicator') as HTMLElement;
    
    if (indicator) {
      indicator.style.transform = `rotate(${angle}deg)`;
    }
  }
  
  private updateLastUpdateTime(): void {
    const now = new Date();
    (document.getElementById('last-update') as HTMLElement).textContent = 
      now.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }
}

// Initialize the app when the DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  new PrayerTimesApp();
});
#include <SPI.h>         // needed for Arduino versions later than 0018
#include <Ethernet.h>
#include <Udp.h>         // UDP library from: bjoern@cs.stanford.edu 12/30/2008

// Stati delle stanze
#define FREE    1
#define BUSY    2
#define UNKNOWN 3
#define OFF     4

// Soglie sensibilità sensori
#define MIC_THRESHOLD 480
#define PIR_THRESHOLD 1023

// Se i sensori non rilevano nulla per questo numero di millisecondi consideriamo la stanza FREE
#define NO_PEAK_INTERVAL  5000

// In modalità di debug il LED della stanza corrente diventerà Rosso
// solo in corrispondenza delle rilevazioni di BUSY di microfono o pir
// per il seguente numero di millisecondi
#define RED_PEAK_DURATION  333

// Il testo dei messaggi UDP
// NB: viene anteposto a queste stringhe l'identificativo dell'arduino che ha generato il messaggio
#define UDP_MSG_FREE   "FREE"
#define UDP_MSG_BUSY   "BUSY"

// Frequenza d'invio dei pacchetti UDP broadcast di aggiornamento di stato verso gli altri Arduino
#define UDP_SEND_STATUS_FREQUENCY  5000

// Se non si ricevono pacchetti dagli altri Arduino per questo numero di millisecondi
// lo stato della stanza diventa UNKNOWN.
// Se NON si ricevono pacchetti per 3 volte questo tempo lo stato diventa OFF.
#define UDP_NO_PACKET_INTERVAL    40000
#define IP_START 100


// Definizione Pin Digitali
int ledRedPins[]    = { 6, 8, 10, 12 };  // Array dei pin dei LED (terminali rossi)
int ledGreenPins[]  = { 7, 9, 11, 13 };  // Array dei pin dei LED (terminali verdi)
int dipSwitchPins[] = { 2, 3,  4,  5 };  // Array dei pin del Dip Switch (L'ultimo pin se On indica modalità di debug)
// Definizione Pin Analogici
int micPin = 0;
int pirPin = 1;

// Istante di ricezione (invio) dell'ultimo pacchetto UPD da/per ciascun Arduino
unsigned long recTime[] = { 0, 0, 0, 0 };

// Stato delle varie stanze
int roomStatus[] = { UNKNOWN, UNKNOWN, UNKNOWN, UNKNOWN };

// Identificativo della stanza corrispondente a questo Arduino
// Valore letto dal Dip Switch (Valori possibili: 0..3)
int thisRoomId = 0;

// Modalità di debug? E' stabilita dal Dip Switch.
boolean debug = false;

// Se il led della stanza corrente mostra in rosso solo il picco del sensore.
// E' stabilita dal Dip Switch.
boolean showPeak = false;

// Istante di rilevazione dell'ultimo picco da uno dei sensori
unsigned long lastPeakTime = 0;

// MAC address della scheda Ethernet
byte mac[] = { 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };

// Indirizzo IP della scheda Ethernet
byte ip[4]  = { 192, 168, 0, IP_START };

// Broadcast IP (dove inviare i pacchetti UDP broadcast)
byte broadcastIp[4] = { 192, 168, 0, 255 };

// Remote IP (da quale indirizzo ho ricevuto l'ultimo pacchetto UDP)
byte remoteIp[4] = { 0, 0, 0, 0 };

// Local port to listen on
unsigned int port = 9876;

// Remote port
unsigned int remotePort;

// Buffer per l'invio e la ricezione dei messaggi UDP
char inBuffer[UDP_TX_PACKET_MAX_SIZE];  // Buffer to hold incoming packet,
char msgBuffer[UDP_TX_PACKET_MAX_SIZE]; // String to send to other device

// Questo flag indica se lo stato BUSY deve essere mostrato o meno in Verde
// Vale solo per la modalità di debug. Vedi RED_PEAK_DURATION
boolean showBusyAsGreen = false;


// Mostra lo stato di una stanza accendendo o spegnendo il LED corrispondente
void showRoomStatus(int roomNumber)
{
  switch (roomStatus[roomNumber]) {
    case FREE:
      // Verde
      digitalWrite(ledRedPins[roomNumber], LOW);
      digitalWrite(ledGreenPins[roomNumber], HIGH);
      break;
    case BUSY:
      if (showPeak && roomNumber == thisRoomId && showBusyAsGreen) {
        // Verde
        digitalWrite(ledRedPins[roomNumber], LOW);
        digitalWrite(ledGreenPins[roomNumber], HIGH);
      } else {
        // Rossi
        digitalWrite(ledRedPins[roomNumber], HIGH);
        digitalWrite(ledGreenPins[roomNumber], LOW);
      }
      break;
    case UNKNOWN:
      // Arancione
      digitalWrite(ledRedPins[roomNumber], HIGH);
      digitalWrite(ledGreenPins[roomNumber], HIGH);
      break;
    case OFF:
      // Spento
      digitalWrite(ledRedPins[roomNumber], LOW);
      digitalWrite(ledGreenPins[roomNumber], LOW);
      break;
  }
  if (debug) {
    Serial.print("Led ");
    Serial.print(roomNumber);
    Serial.print(" ");
    Serial.println(getUdpMessageStatus(roomStatus[roomNumber]));
  }
}


// Restituisce il messaggio UDP corrispondente allo stato passato
char* getUdpMessageStatus(int deviceStatus)
{
  switch (deviceStatus) {
    case FREE:
      return UDP_MSG_FREE;
      break;
    case BUSY:
      return UDP_MSG_BUSY;
      break;
    case UNKNOWN:
      return "UNKNOWN";
    case OFF:
      return "OFF";
    default:
      return "IGNORE";
  }
}


// Aggiorna lo stato della stanza di questo Arduino
// e lo visualizza sul Led corrispondente. 
// Ritorna true se lo stato è cambiato.
boolean updateStatusOfThisRoom()
{
  int oldStatus = roomStatus[thisRoomId];
 
  // Microfono
  int micValue = analogRead(micPin);
  //debugValue("Microfono", micValue);

  if (micValue > MIC_THRESHOLD) {
    lastPeakTime = millis();
    roomStatus[thisRoomId] = BUSY;
  }

  // Sensore di movimento
  int pirValue = analogRead(pirPin);
  //debugValue("PIR", pirValue);
  if (pirValue > PIR_THRESHOLD) {
    lastPeakTime = millis();
    roomStatus[thisRoomId] = BUSY;
  }

  unsigned long clock = millis();
  if (roomStatus[thisRoomId] == BUSY) {
    if (clock < lastPeakTime) {
      // Gestione clock overflow
      lastPeakTime = 0;
    }
    if (clock > lastPeakTime + NO_PEAK_INTERVAL) {
      // Sono trascorsi "noPeakInterval" millisecondi senza rilevare picchi su microfono e pir
      // La risorsa monitorata da Artuino diventa FREE
      roomStatus[thisRoomId] = FREE;
    }
    // NB: In modalità di debug il LED della stanza corrente diventerà Rosso
    //     solo in corrispondenza delle rilevazioni di BUSY di microfono o pir
    //     per soli RED_PEAK_DURATION millisecondi
    showBusyAsGreen = (showPeak && clock > lastPeakTime + RED_PEAK_DURATION);
  } else {
    roomStatus[thisRoomId] = FREE;
  }
  boolean statusChanged = (roomStatus[thisRoomId] != oldStatus);
  if (statusChanged || (debug && roomStatus[thisRoomId] == BUSY)) {
    showRoomStatus(thisRoomId);
  }
  return statusChanged;
}


// Stampa sulla seriale il valore intero indicato
void debugValue(char* str, int value)
{
  if (debug) {
    Serial.print(str);
    Serial.print("=");
    Serial.print(value);
    Serial.println();
  }
}


// Stampa sulla seriale le informazioni di un Pacchetto
void debugPacket(char* str, byte ip[], int port, char* packet)
{
  if (debug) {
    Serial.print(str);
    Serial.print(" ");
    Serial.print(int(ip[0]));
    Serial.print(".");
    Serial.print(int(ip[1]));
    Serial.print(".");
    Serial.print(int(ip[2]));
    Serial.print(".");
    Serial.print(int(ip[3]));
    Serial.print(":");
    Serial.print(port);
    if (packet != "") {
      Serial.print(" \"");
      Serial.print(packet);
      Serial.println("\"");
    } else {
      Serial.println();
    }
  }
}


// Gestione di un Pacchetto UDP rivevuto
void handleReceivedPacket(byte remoteIp[], char message[])
{
  // TODO: stabilire come determinare il roomNumber.
  // Dall'IP o da un identificativo dentro al pacchetto?
  
  //int roomNumber = remoteIp[3] - IP_START;
  int roomNumber = int(message[0]) - int('0');
  for (int i=1; i<=strlen(message); i++) {
     message[i-1] = message[i];
  }
  
  if (debug) {
    Serial.print("RoomNumber recognized=");
    Serial.print(roomNumber);
    Serial.print(" Message recognized=[");
    Serial.print(message);
    Serial.println("]");
  }
  
  if (roomNumber == thisRoomId) {
    debugValue("Rilevamento conflitto sul RoomNumber", roomNumber);
  } else if (roomNumber >= 0 && roomNumber < 4) {
    if (strcmp(message, UDP_MSG_FREE) == 0) {
      recTime[roomNumber] = millis();
      roomStatus[roomNumber] = FREE;
      showRoomStatus(roomNumber);
    } else if (strcmp(message, UDP_MSG_BUSY) == 0) {
      recTime[roomNumber] = millis();
      roomStatus[roomNumber] = BUSY;
      showRoomStatus(roomNumber);
    } else if (debug) {
      Serial.println("Messaggio ignorato!");
    }
  }
}


// Aggiorna lo stato (e corrispettivi Led) delle altre stanze in UNKNOWN (successivamente in OFF)
// se non si ricevono pacchetti UDP di aggiornamento di stato dagli altri Arduino
// per un lungo intervallo di tempo (UDP_NO_PACKET_INTERVAL millisecondi)
void checkAndUpdateStatusOfOtherRooms()
{
  unsigned long clock = millis();
  for (int i=0; i<4; i++) {
    if (i != thisRoomId) {
      if (clock < recTime[i]) {
        // Gestione clock overflow
        recTime[i] = 0;
      }
      if (roomStatus[i] < UNKNOWN) {
        if (clock > recTime[i] + UDP_NO_PACKET_INTERVAL) {
	  roomStatus[i] = UNKNOWN;
          showRoomStatus(i);
        }
      } else if (roomStatus[i] == UNKNOWN) {
        if (clock > recTime[i] + 3 * UDP_NO_PACKET_INTERVAL) {
          roomStatus[i] = OFF;
	  showRoomStatus(i);
        }
      }
    }
  }
}


// E' ora d'inviare agli altri Arduino un aggiornamento dello stato della stanza corrente?
boolean itsTimeToSendAnUpdate()
{
  unsigned long clock = millis();
  return (clock < recTime[thisRoomId])  // Clock overflow
      || (clock > recTime[thisRoomId] + UDP_SEND_STATUS_FREQUENCY) // Sono trascorsi UDP_SEND_STATUS_FREQUENCY millisecondi dall'ultimo invio
      ;
}


// Legge dal Dip Switch il numero intero (Gli interruttori On/Off sono interpretati come bit)
int dipSwitchRead()
{
  int result = 0;
  for (int i = 0; i < 4; i++) {
    int digitalValue = digitalRead(dipSwitchPins[i]);
    // Il Dip Switch è coonfigurato sulle porte digitali in Pull up Resistor
    // Acceso = LOW.
    if (digitalValue == LOW) {
      result += (1 << i);
    }
  }
  // Siamo in modalità di debug se è HIGH il quarto pin del Dip Switch
  debug = (result & 8); 
  showPeak = (result & 4);
  return result;
}


void setup()
{
  // Start serial
  Serial.begin(57600);
  
  analogReference(DEFAULT);
  delay(1500);
  
  // Setup digital pins (INPUT/OUTPUT)
  for (int i = 0; i < 4; i++) {
    pinMode(ledRedPins[i], OUTPUT);
    pinMode(ledGreenPins[i], OUTPUT);
    pinMode(dipSwitchPins[i], INPUT);
    digitalWrite(dipSwitchPins[i], HIGH); // Set pullup resistor on
  }

  // Lettura valore decimale impostato sul dip switch
  int dipSwitchValue = dipSwitchRead();
  debugValue("Dip Switch", dipSwitchValue);

  // I primi 2 pin del dipSwitch determinano l'identificativo numerico dato a questo Arduino 
  thisRoomId = (dipSwitchValue % 4);

  // Visualizzazione dello stato iniziale dei Led (UNKNOWN)
  for (int i=0; i<4; i++) {
    showRoomStatus(i);
  }

  // Set dell'ultimo numero dell'indirizzo IP e del MAC Address
  ip[3] = IP_START + thisRoomId;
  mac[5] = thisRoomId;
  debugPacket("IP Address:", ip, port, "");

  // Start Ethernet and UDP
  Ethernet.begin(mac, ip);
  Udp.begin(port);
  
  delay(2000);
}



void loop()
{
  int packetSize = Udp.available(); // note that this includes the UDP header
  if (packetSize) {
    packetSize = packetSize - 8; // subtract the 8 byte header
    // Lettura pacchetto
    Udp.readPacket(inBuffer, UDP_TX_PACKET_MAX_SIZE, remoteIp, remotePort);
    debugPacket("Received Packet:", remoteIp, remotePort, inBuffer);
    handleReceivedPacket(remoteIp, inBuffer);
  }
  
  // Aggiorna lo stato (e i Led) delle altre stanze
  // se non si ricevono pacchetti di aggiornamento dalla rete
  checkAndUpdateStatusOfOtherRooms();
  
  // Aggiornamento dello stato di questa stanza (utilizzando i sensori)
  boolean statusChanged = updateStatusOfThisRoom();
  
  if (statusChanged || itsTimeToSendAnUpdate()) {
    // Invio aggiornamento di stato in broadcast
    String strBuffer = String(thisRoomId) + getUdpMessageStatus(roomStatus[thisRoomId]);
    strBuffer.toCharArray(msgBuffer, UDP_TX_PACKET_MAX_SIZE);
    Udp.sendPacket(msgBuffer, broadcastIp, port);
    debugPacket("Sent Packet:", broadcastIp, port, msgBuffer);
    recTime[thisRoomId] = millis();
  }
}



